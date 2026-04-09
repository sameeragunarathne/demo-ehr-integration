// EHR Integration — Mosaic-specific FHIR data mappings
//
// While Mosaic supports FHIR, it requires:
//   • A specific patient profile URL stamped on meta.profile
//   • A mandatory "patient-primary-facility" extension carrying a
//     Location UUID (not the raw facility string CompuLink sends).
//
// Mapping rule demonstrated:
//   CompuLink's MSH-4 sending facility code (e.g. "CLINIC_NORTH") is
//   translated into Mosaic's Location UUID reference using a lookup table.
//   Unknown facility codes receive a deterministic UUID v5 generated from
//   the code name, so the mapping is always consistent across runs.

import ballerina/uuid;
import ballerinax/health.fhir.r4;
import ballerinax/health.fhir.r4.international401;
import ballerinax/health.hl7v23;

// ── Facility code → [UUID, Display] lookup ───────────────────────────────────
//
// Add new entries here as more CompuLink clinics are on-boarded to Mosaic.
// The UUID for "Springfield Main Campus" matches the example in the
// integration specification (f81d4fae-7dec-11d0-a765-00a0c91e6bf6).

final map<[string, string]> & readonly FACILITY_UUID_MAP = {
    "CLINIC_NORTH": ["f81d4fae-7dec-11d0-a765-00a0c91e6bf6", "Springfield Main Campus"],
    "CLINICLINK":   ["f81d4fae-7dec-11d0-a765-00a0c91e6bf6", "Springfield Main Campus"],
    "CLINIC_SOUTH": ["a3b8d2e1-5f9c-4d7a-8e2b-1c6f0d9e7a8b", "Springfield South Clinic"],
    "CLINIC_EAST":  ["c7e4f9b2-8a1d-4c6e-9f3a-2b5e0c8d1f4a", "Springfield East Clinic"]
};

// ── mapMosaicPatient ──────────────────────────────────────────────────────────

# Maps a CompuLink HL7 ADT_A04 patient to a Mosaic-profiled
# `international401:Patient` using Ballerina's data-mapping expression style.
#
# Mosaic-specific additions produced here:
#   • `meta.profile`  — Mosaic patient profile canonical URL
#   • `extension`     — patient-primary-facility with Location UUID
#   • `identifier`    — MRN from PID-3 typed to Mosaic's identifier system
#   • `name`          — official name from PID-5
#
# The caller (`processBundle`) deep-merges this with the standard v2tofhir
# base bundle entry so no fields from the standard transform are lost.
#
# + incomingMessage - Parsed HL7 ADT_A04
# + return - Mosaic-profiled `international401:Patient` or an error
public isolated function mapMosaicPatient(hl7v23:ADT_A04 incomingMessage)
        returns international401:Patient|error => let

    // ── extract fields from HL7 segments ─────────────────────────────────────
    var familyName   = incomingMessage.pid.pid5[0].xpn1,
    var givenName    = incomingMessage.pid.pid5[0].xpn2,
    var mrn          = incomingMessage.pid.pid3[0].cx1,
    var facilityCode = incomingMessage.msh.msh4.hd1,

    // ── resolve CompuLink facility code → Mosaic Location UUID ───────────────
    [string, string] [facilityUuid, facilityDisplay] = check getFacilityInfo(facilityCode),

    // ── Mosaic patient profile ────────────────────────────────────────────────
    r4:canonical[] profiles = ["http://mosaic.com/fhir/StructureDefinition/mosaic-patient"],

    // ── MRN identifier typed to CompuLink's assigning authority ──────────────
    r4:Identifier mrnIdentifier = {
        system: "http://compulink.com/fhir/patient-id",
        value:  mrn,
        use:    "usual"
    },

    // ── official patient name from PID-5 ─────────────────────────────────────
    r4:HumanName officialName = {
        use:    "official",
        family: familyName,
        given:  [givenName]
    },

    // ── primary-facility extension: facility code → Location UUID reference ──
    //
    //   Mapping rule:  "CLINIC_NORTH"
    //                      ↓
    //   Location/urn:uuid:f81d4fae-7dec-11d0-a765-00a0c91e6bf6
    //                      ("Springfield Main Campus")
    r4:Extension facilityExtension = {
        url: "http://mosaic.com/fhir/StructureDefinition/patient-primary-facility",
        valueReference: {
            reference: "Location/urn:uuid:" + facilityUuid,
            display:   facilityDisplay
        }
    }

    in {
        meta:       {profile: profiles},
        identifier: [mrnIdentifier],
        name:       [officialName],
        extension:  [facilityExtension]
    };

// ── Facility lookup helper ────────────────────────────────────────────────────

# Resolves a CompuLink facility code to a `[uuid, displayName]` tuple.
# Known codes are looked up in `FACILITY_UUID_MAP` (case-insensitive).
# Unknown codes receive a deterministic UUID v5 (DNS namespace + lower-cased
# facility code) so the same unknown code always maps to the same UUID.
#
# + facilityCode - Raw facility string from MSH-4
# + return - `[uuid, displayName]` tuple or an error from UUID generation
isolated function getFacilityInfo(string facilityCode) returns [string, string]|error {
    string upperCode = facilityCode.toUpperAscii();
    if FACILITY_UUID_MAP.hasKey(upperCode) {
        return FACILITY_UUID_MAP.get(upperCode);
    }
    // Deterministic UUID v5 for unknown facilities — consistent across runs
    string generatedUuid = check uuid:createType5AsString(uuid:NAME_SPACE_DNS, facilityCode.toLowerAscii());
    return [generatedUuid, facilityCode + " (Auto-mapped)"];
}
