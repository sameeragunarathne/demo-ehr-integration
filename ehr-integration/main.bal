// EHR Integration Service (WSO2 Integrator mock)
// Scenario 1:
//   1. Listens for HL7 ADT^A04 messages via MLLP (TCP port 59519)
//   2. Parses the HL7 message
//   3. Transforms HL7 v2.3 -> FHIR R4 Bundle using v2tofhirr4
//   4. POSTs the FHIR Bundle to Mosaic EMR (HTTP)
//   5. Sends HL7 ACK back to CompuLink EHR

import ballerina/log;
import ballerina/tcp;
import ballerinax/health.clients.fhir as fhir_client;
import ballerinax/health.fhir.r4;
import ballerinax/health.hl7v2;
import ballerinax/health.hl7v23;
import ballerinax/health.hl7v23.utils.v2tofhirr4;

// MLLP framing bytes
const byte MLLP_START = 0x0B;   // VT  - start of HL7 message block

// Mosaic EMR base FHIR URL — the FHIR client appends /{resourceType} automatically
// (e.g. "http://localhost:8081/fhir"  →  POST http://localhost:8081/fhir/Bundle)
configurable string mosaicFhirBaseUrl = "http://localhost:8081/fhir";

// FHIR client for Mosaic EMR — no auth (plain HTTP), CapabilityStatement
// validation disabled because the Mosaic mock does not expose a metadata endpoint
final fhir_client:FHIRConnector mosaicFhirClient = check new (
    {
        baseURL: mosaicFhirBaseUrl,
        mimeType: fhir_client:FHIR_JSON
    },
    enableCapabilityStatementValidation = false
);

// ── MLLP TCP Listener ────────────────────────────────────────────────────────

service on new tcp:Listener(59519) {
    remote function onConnect(tcp:Caller caller) returns tcp:ConnectionService {
        log:printInfo("EHR-Integration: CompuLink EHR connected from port " + caller.remotePort.toString());
        return new HL7ConnectionService();
    }
}

service class HL7ConnectionService {
    *tcp:ConnectionService;

    remote function onBytes(tcp:Caller caller, readonly & byte[] data) returns tcp:Error? {
        // Delegate all processing; onBytes must only return tcp:Error?
        error? result = processHL7Message(caller, data);
        if result is error {
            log:printError("EHR-Integration [ERROR]: " + result.message());
        }
    }

    remote function onError(tcp:Error err) {
        log:printError("EHR-Integration [TCP ERROR]: " + err.message());
    }

    remote function onClose() {
        log:printInfo("EHR-Integration: CompuLink EHR disconnected");
    }
}

// ── Message Processing Pipeline ─────────────────────────────────────────────

function processHL7Message(tcp:Caller caller, readonly & byte[] data) returns error? {
    log:printInfo("");
    log:printInfo("EHR-Integration: ── Incoming HL7 message ──────────────────────────");

    // Step 1: Extract raw HL7 string (strip MLLP framing for v2ToFhir)
    string hl7String = check extractHl7String(data);
    log:printInfo("EHR-Integration: Raw HL7:\n" + hl7String);

    // Step 2: Parse HL7 — generic Message (for processBundle) + typed ADT_A04
    //         (for control-ID / patient logging).
    hl7v2:Message hl7Message = check hl7v2:parse(data);
    string msgControlId = "UNKNOWN";
    hl7v23:ADT_A04|error typedMsg = hl7Message.cloneWithType(hl7v23:ADT_A04);
    if typedMsg is hl7v23:ADT_A04 {
        msgControlId = typedMsg.msh.msh10;
        string patientName = typedMsg.pid.pid5.length() > 0
            ? typedMsg.pid.pid5[0].xpn2 + " " + typedMsg.pid.pid5[0].xpn1
            : "Unknown";
        string mrn = typedMsg.pid.pid3.length() > 0 ? typedMsg.pid.pid3[0].cx1 : "Unknown";
        log:printInfo("EHR-Integration: ADT^A04 for patient : " + patientName + " (MRN: " + mrn + ")");
        log:printInfo("EHR-Integration: Message Control ID  : " + msgControlId);
    } else {
        log:printWarn("EHR-Integration: [WARN] Could not cast to ADT_A04, proceeding with generic parse");
    }

    // Step 3: Standard HL7 v2.3 → FHIR R4 Bundle (v2tofhirr4 transformer)
    log:printInfo("EHR-Integration: Transforming HL7 -> FHIR R4 Bundle (standard)...");
    json baseFhirJson = check v2tofhirr4:v2ToFhir(hl7String);
    log:printInfo("EHR-Integration: ── Standard FHIR Bundle ──────────────────────────");
    log:printInfo(baseFhirJson.toString());

    // Step 4: Apply Mosaic-specific enrichments via data-mapper
    //   • Casts the Patient entry to international401:Patient (cloneWithType)
    //   • Stamps meta.profile with Mosaic patient profile URL
    //   • Injects patient-primary-facility extension (facility code → UUID)
    //   • Deep-merges v2tofhir base (precedence) + Mosaic additions
    log:printInfo("EHR-Integration: Applying Mosaic data-mapper enrichments...");
    r4:Bundle baseFhirBundle = check baseFhirJson.cloneWithType(r4:Bundle);
    r4:Bundle enrichedBundle = check processBundle(baseFhirBundle, hl7Message);
    json enrichedFhirJson = enrichedBundle.toJson();
    log:printInfo("EHR-Integration: ── Mosaic-enriched FHIR Bundle ────────────────────");
    log:printInfo(enrichedFhirJson.toString());

    // Step 5: POST enriched FHIR Bundle to Mosaic EMR via FHIR client
    //   The FHIR client extracts "resourceType": "Bundle" from the JSON and
    //   resolves the target to  {mosaicFhirBaseUrl}/Bundle  automatically.
    log:printInfo("EHR-Integration: Sending enriched Bundle via FHIR client to " + mosaicFhirBaseUrl + "...");
    fhir_client:FHIRResponse fhirResponse = check mosaicFhirClient->'transaction(enrichedFhirJson);
    log:printInfo("EHR-Integration: Mosaic EMR responded with HTTP " + fhirResponse.httpStatusCode.toString());

    if fhirResponse.httpStatusCode != 201 {
        return error("Mosaic EMR returned unexpected status: " + fhirResponse.httpStatusCode.toString());
    }

    // Step 6: Send HL7 ACK (AA) back to CompuLink EHR via MLLP
    byte[] ackMllp = check buildMllpAck(msgControlId);
    check caller->writeBytes(ackMllp);
    log:printInfo("EHR-Integration: ACK sent to CompuLink EHR (Control ID: " + msgControlId + ")");
    log:printInfo("EHR-Integration: ── Pipeline complete ──────────────────────────────");
}

// ── Helper: Strip MLLP framing and return plain HL7 string ──────────────────

function extractHl7String(readonly & byte[] data) returns string|error {
    byte[] hl7Bytes = data;
    // Strip leading VT (0x0B) and trailing FS+CR (0x1C 0x0D)
    if data.length() > 3 && data[0] == MLLP_START {
        hl7Bytes = data.slice(1, data.length() - 2);
    }
    return string:fromBytes(hl7Bytes);
}

// ── Helper: Build MLLP-framed HL7 ACK message ───────────────────────────────

function buildMllpAck(string originalControlId) returns byte[]|error {
    hl7v23:ACK ack = {
        msh: {
            msh3: {hd1: "EHR-Integration"},
            msh4: {hd1: "WSO2"},
            msh5: {hd1: "CompuLink"},
            msh6: {hd1: "ClinicLink"},
            msh7: {ts1: "20260409120000"},
            msh9: {cm_msg1: "ACK"},
            msh10: "ACK-" + originalControlId,
            msh11: {pt1: "P"},
            msh12: "2.3"
        },
        msa: {
            msa1: "AA",                                     // Application Accept
            msa2: originalControlId,                        // echo original control ID
            msa3: "Message accepted and forwarded to Mosaic EMR"
        }
    };

    return hl7v2:encode(hl7v23:VERSION, ack);
}

