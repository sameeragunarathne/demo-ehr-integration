// CompuLink EHR Mock
// Scenario 1: Sends an HL7 ADT^A04 (Register Patient) message via MLLP to
// the EHR Integration service and waits for an ACK.
//
// Two modes:
//   1. Default  — programmatically built hl7v23:ADT_A04 struct (John Doe, MRN 993412)
//   2. Override — supply a raw HL7 pipe-delimited string via Config.toml or
//                 `-C hl7MsgString="MSH|^~\\&|..."` on the command line;
//                 the string is parsed with stringToHl7() and sent as-is.

import ballerinax/health.hl7v2;
import ballerinax/health.hl7v23;
import ballerina/log;

// EHR Integration MLLP listener endpoint
configurable string ehrIntegrationHost = "localhost";
configurable int ehrIntegrationPort = 59519;


// ── Utility ──────────────────────────────────────────────────────────────────

# Parses a raw HL7 pipe-delimited string into a generic `hl7v2:Message`.
# Mirrors the helper exposed by the v2tofhirr4 library.
#
# + msg - Raw HL7 message string (segment separator = `\r`)
# + return - Parsed `hl7v2:Message` or an error
public isolated function stringToHl7(string msg) returns hl7v2:Message|error =>
    check hl7v2:parse(msg);

// ── Entry point ───────────────────────────────────────────────────────────────

public function main(string? hl7MsgString = ()) returns error? {
    hl7v2:Message msgToSend;

    if hl7MsgString != "" && hl7MsgString != () {
        // ── Mode 2: parse the supplied raw HL7 string ──
        log:printInfo("=== CompuLink EHR: Parsing provided HL7 message string ===");
        msgToSend = check stringToHl7(<string>hl7MsgString);
        log:printInfo("Parsed message type : " + msgToSend.name);
    } else {
        // ── Mode 1: build ADT^A04 programmatically ──
        hl7v23:ADT_A04 adtA04 = {
            msh: {
                msh3: {hd1: "CompuLink"},
                msh4: {hd1: "ClinicLink"},
                msh5: {hd1: "EHR-Integration"},
                msh6: {hd1: "WSO2"},
                msh7: {ts1: "20260409120000"},
                msh9: {cm_msg1: "ADT", cm_msg2: "A04"},
                msh10: "MSG-CL-001",
                msh11: {pt1: "P"},
                msh12: "2.3"
            },
            evn: {
                evn1: "A04",
                evn2: {ts1: "20260409120000"}
            },
            pid: {
                pid3: [
                    {
                        cx1: "993412",
                        cx4: {hd1: "CompuLink"},
                        cx5: "MR"
                    }
                ],
                pid5: [
                    {
                        xpn1: "Doe",
                        xpn2: "John",
                        xpn3: "A"
                    }
                ],
                pid7: {ts1: "19850315"},
                pid8: "M",
                pid11: [
                    {
                        xad1: "123 Main St",
                        xad3: "Springfield",
                        xad4: "IL",
                        xad5: "62701",
                        xad6: "USA"
                    }
                ],
                pid13: [{xtn1: "(555) 555-1234"}]
            },
            pv1: {
                pv12: "O"   // O = Outpatient (pre-registration)
            }
        };
        msgToSend = adtA04;
    }

    log:printInfo("=== CompuLink EHR: Sending ADT^A04 (Register Patient) ===");
    log:printInfo("Patient  : John Doe");
    log:printInfo("MRN      : 993412");
    log:printInfo("Event    : A04 - Register a Patient");
    log:printInfo("Target   : " + ehrIntegrationHost + ":" + ehrIntegrationPort.toString());
    log:printInfo("");

    // HL7Client handles MLLP framing (VT + message + FS + CR) automatically
    hl7v2:HL7Client hl7Client = check new (ehrIntegrationHost, ehrIntegrationPort);
    hl7v2:Message ackMsg = check hl7Client.sendMessage(msgToSend);

    log:printInfo("=== CompuLink EHR: Received ACK ===");
    log:printInfo(ackMsg.toJsonString());
}
