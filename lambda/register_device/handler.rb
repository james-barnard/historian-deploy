require "json"
require "aws-sdk-dynamodb"
require "securerandom"

# register-device Lambda
#
# Called during factory provisioning: POST /v1/register-device
# Protected by a factory provisioning secret.
# Idempotent: if device already registered, returns existing token.
#
# Request:
#   { "factory_secret": "...", "device_id": "HX-abc12345", "platform": "gx10" }
#
# Response:
#   { "device_id": "HX-abc12345", "token": "generated-uuid", "status": "registered" }

DEVICES_TABLE = ENV["DEVICES_TABLE"] || "historian-devices"
FACTORY_SECRET = ENV["FACTORY_SECRET"] || "CHANGE_ME"

def handler(event:, context:)
  body = JSON.parse(event["body"] || "{}")

  factory_secret = body["factory_secret"]
  device_id = body["device_id"]
  platform = body["platform"]

  # Validate factory secret
  unless factory_secret == FACTORY_SECRET
    return response(403, { error: "Invalid factory credentials" })
  end

  unless device_id
    return response(400, { error: "Missing required field: device_id" })
  end

  dynamodb = Aws::DynamoDB::Client.new

  # Idempotent: check if device already registered
  existing = dynamodb.get_item(
    table_name: DEVICES_TABLE,
    key: { "device_id" => device_id }
  ).item

  if existing
    # Already registered — return existing token
    return response(200, {
      device_id: device_id,
      token: existing["token"],
      status: "already_registered",
    })
  end

  # Generate unique token
  token = SecureRandom.uuid

  # Register device
  dynamodb.put_item(
    table_name: DEVICES_TABLE,
    item: {
      "device_id" => device_id,
      "token" => token,
      "platform" => platform || "unknown",
      "registered_at" => Time.now.utc.iso8601,
      "version" => "0.0.0",
      "last_checkin" => nil,
      "telemetry" => {},
    },
    condition_expression: "attribute_not_exists(device_id)",
  )

  response(200, {
    device_id: device_id,
    token: token,
    status: "registered",
  })
rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
  # Race condition: another request registered it first — fetch and return
  existing = dynamodb.get_item(
    table_name: DEVICES_TABLE,
    key: { "device_id" => device_id }
  ).item

  response(200, {
    device_id: existing["device_id"],
    token: existing["token"],
    status: "already_registered",
  })
end

private

def response(status_code, body)
  {
    statusCode: status_code,
    headers: { "Content-Type" => "application/json" },
    body: JSON.generate(body),
  }
end
