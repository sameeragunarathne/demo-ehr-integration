// Custom Patient Service
// Accepts a custom (non-FHIR) JSON payload describing a patient and
// responds with HTTP 201 Created.

import ballerina/http;
import ballerina/log;
import ballerina/uuid;

configurable int port = 8082;

# Custom patient payload accepted by this service.
public type CustomPatient record {|
    string mrn;
    string firstName;
    string lastName;
    string dateOfBirth;
    string gender;
    string? phone?;
    string? email?;
    Address? address?;
|};

public type Address record {|
    string line;
    string city;
    string state;
    string postalCode;
    string country;
|};

service /patients on new http:Listener(port) {

    # Accepts a custom patient JSON payload and returns 201 Created.
    # + patient - Custom patient payload
    # + return - `http:Created` on success or `http:BadRequest` if the payload is invalid
    resource function post .(@http:Payload json patient) returns http:Created|http:BadRequest {
        string id = uuid:createType4AsString();

        log:printInfo("Custom Patient Service: Received patient record",
                payload = patient);

        http:Created response = {
            headers: {
                "Location": "/patients/" + id,
                "Content-Type": "application/json"
            },
            body: {
                "id": id,
                "status": "created",
                "message": "Patient registered successfully"
            }
        };
        return response;
    }
}
