// EHR Integration — bundle processing utilities
//
// processBundle: walks every entry in the standard v2tofhir FHIR Bundle and
//   applies Mosaic-specific enrichments (defined in data_mappings.bal).
//   Patient entries are enriched; all others pass through unchanged.
//
// deepMergeJson: recursive JSON merge where the FIRST argument takes
//   precedence.  Used to overlay Mosaic additions onto the v2tofhir base
//   without losing any standard fields produced by the transformer.

import ballerinax/health.fhir.r4;
import ballerinax/health.hl7v2;
import ballerinax/health.hl7v23;

// ── processBundle ─────────────────────────────────────────────────────────────

# Walks every entry in a standard v2tofhir FHIR Bundle and applies
# Mosaic-specific enrichments.
#
# For Patient entries the flow is:
#   1. Cast the generic `r4:Resource` to `international401:Patient` via
#      `cloneWithType` (done inside `mapMosaicPatient`).
#   2. Build the Mosaic-enriched patient (profile + facility extension).
#   3. Deep-merge: v2tofhir base (first / higher precedence) +
#      Mosaic additions (second) — so standard fields are never lost.
#   4. Cast the merged JSON back to `r4:Resource` and push to the bundle.
#
# Non-Patient entries are pushed through unchanged.
#
# + bundle      - Standard FHIR R4 Bundle from v2tofhirr4 transformer
# + incomingMsg - Generic `hl7v2:Message` (cloneWithType to ADT_A04 inside)
# + return - Mosaic-enriched `r4:Bundle` or an error
public isolated function processBundle(r4:Bundle bundle, hl7v2:Message incomingMsg)
        returns r4:Bundle|error {

    r4:BundleEntry[] updatedEntries = [];
    r4:BundleEntry[] entries = <r4:BundleEntry[]>bundle.entry;

    foreach var entry in entries {
        r4:Resource baseResource = check entry?.'resource.cloneWithType(r4:Resource);
        string resourceType = baseResource.resourceType;
        r4:Resource? enriched = ();

        if resourceType.equalsIgnoreCaseAscii("Patient") {
            // Cast hl7v2:Message → hl7v23:ADT_A04 and run through the data-mapper.
            // The data-mapper is a pure HL7→FHIR expression; baseResource is merged
            // back via deepMergeJson below so no v2tofhir fields are lost.
            enriched = check mapMosaicPatient(
                check incomingMsg.cloneWithType(hl7v23:ADT_A04)
            );
        }

        if enriched is r4:Resource {
            // Deep-merge: v2tofhir base fields take precedence;
            // Mosaic additions (profile, extension) fill in what is new.
            json merged = check deepMergeJson(baseResource.toJson(), enriched.toJson());
            r4:Resource mergedResource = check merged.cloneWithType(r4:Resource);
            updatedEntries.push({'resource: mergedResource});
        } else {
            // Non-patient resources pass through unmodified
            updatedEntries.push(entry);
        }
    }

    bundle.entry = updatedEntries;
    return bundle;
}

// ── deepMergeJson ─────────────────────────────────────────────────────────────

# Recursively merges two JSON objects. The **first** argument takes
# precedence: its scalar / array values override those of the second.
# New keys that exist only in the second object are included in the result.
#
# Rules:
#  • Nested objects  → merged recursively (first wins on conflict)
#  • Single-element arrays on both sides → the elements are deep-merged
#  • Multi-element arrays → concatenated, first object's items first
#  • Empty strings and empty arrays → skipped (not written to result)
#  • Non-object JSON (string, int, …) → first value returned as-is
#
# + firstJson  - Base JSON object (higher precedence)
# + secondJson - Overlay JSON object (adds fields absent from first)
# + return - Merged JSON or an error
public isolated function deepMergeJson(json firstJson, json secondJson) returns json|error {
    if !(firstJson is map<json>) || !(secondJson is map<json>) {
        // Non-object: first always wins
        return firstJson;
    }

    map<json> result = {};
    map<json> firstMap  = <map<json>>firstJson;
    map<json> secondMap = <map<json>>secondJson;

    // Seed result with all fields from secondJson
    foreach var [key, val] in secondMap.entries() {
        if val is string && val == "" { continue; }
        if val is json[] && val.length() == 0 { continue; }
        result[key] = val;
    }

    // Apply firstJson fields with precedence, merging where possible
    foreach var [key, val] in firstMap.entries() {
        if val is string && val == "" { continue; }
        if val is json[] && val.length() == 0 { continue; }

        if val is map<json> && result.hasKey(key) && result[key] is map<json> {
            // Recurse into nested objects
            result[key] = check deepMergeJson(val, result[key]);

        } else if val is json[] && result.hasKey(key) && result[key] is json[] {
            json[] firstArr  = <json[]>val;
            json[] secondArr = <json[]>result[key];

            if firstArr.length() == 1 && secondArr.length() == 1 {
                // Single-element arrays: deep-merge the elements
                result[key] = (val[0] is map<json> && secondArr[0] is map<json>)
                    ? [check deepMergeJson(val[0], secondArr[0])]
                    : [firstArr[0]];
            } else {
                // Multi-element arrays: concatenate (first's items first)
                result[key] = [...firstArr, ...secondArr];
            }
        } else {
            result[key] = val;
        }
    }

    return result;
}
