// Mosaic EMR Mock
// Scenario 1: Accepts FHIR R4 Bundles from the EHR Integration service
// and responds with HTTP 201 Created.

import ballerina/http;
import ballerina/log;

configurable int port = 8081;

service /fhir on new http:Listener(port) {

    # Accepts a FHIR R4 Bundle (transaction) from EHR Integration.
    # Returns 201 Created with a minimal Bundle response.
    # + return - `http:Created` on success or `http:InternalServerError` on failure
    resource function post .(http:Request request) returns http:Created|http:InternalServerError {
        json|error payload = request.getJsonPayload();

        if payload is json {
            log:printInfo("");
            log:printInfo("Mosaic EMR: Received FHIR Bundle");
            log:printInfo("Mosaic EMR: Payload preview: ", payload = payload);
            log:printInfo("Mosaic EMR: Responding with 201 Created");
        } else {
            log:printError("Mosaic EMR: [WARN] Could not parse request body as JSON: " + payload.message());
        }

        // Return 201 Created with a transaction-response Bundle
        http:Created response = {
            headers: {
                "Location": "/fhir/Bundle/mosaic-bundle-001",
                "Content-Type": "application/fhir+json"
            },
            body: {
                "resourceType": "Bundle",
                "id": "mosaic-bundle-001",
                "type": "transaction-response",
                "entry": [
                    {
                        "response": {
                            "status": "201 Created",
                            "location": "Patient/993412"
                        }
                    }
                ]
            }
        };
        return response;
    }
}
