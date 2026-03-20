require "json"
require "aws-sdk-dynamodb"
require "aws-sdk-s3"
require "digest"

# check-update Lambda
#
# Called by devices via API Gateway: POST /v1/check-update
# 1. Verifies device token against DynamoDB devices table
# 2. Logs telemetry to devices table
# 3. Checks rollout rules against releases table
# 4. Returns presigned S3 URL if update available

RELEASES_TABLE = ENV["RELEASES_TABLE"] || "historian-releases"
DEVICES_TABLE = ENV["DEVICES_TABLE"] || "historian-devices"
S3_BUCKET = ENV["S3_BUCKET"] || "historian-releases"
PRESIGN_EXPIRY = 300 # 5 minutes

def handler(event:, context:)
  body = JSON.parse(event["body"] || "{}")

  device_id = body["device_id"]
  token = body["token"]
  version = body["version"]
  telemetry = body["telemetry"] || {}

  # Validate required fields
  unless device_id && token && version
    return response(400, { error: "Missing required fields: device_id, token, version" })
  end

  dynamodb = Aws::DynamoDB::Client.new
  s3 = Aws::S3::Client.new

  # Step 1: Verify device token
  begin
    device = dynamodb.get_item(
      table_name: DEVICES_TABLE,
      key: { "device_id" => device_id }
    ).item

    unless device && device["token"] == token
      return response(403, { error: "Invalid device credentials" })
    end
  rescue Aws::DynamoDB::Errors::ResourceNotFoundException
    return response(403, { error: "Invalid device credentials" })
  end

  # Step 2: Log telemetry
  dynamodb.update_item(
    table_name: DEVICES_TABLE,
    key: { "device_id" => device_id },
    update_expression: "SET #v = :v, last_checkin = :now, telemetry = :t",
    expression_attribute_names: { "#v" => "version" },
    expression_attribute_values: {
      ":v" => version,
      ":now" => Time.now.utc.iso8601,
      ":t" => telemetry,
    }
  )

  # Step 3: Find latest release with rollout > 0
  latest = find_latest_release(dynamodb)
  unless latest
    return response(200, { update_available: false })
  end

  # Already on latest?
  if version == latest["version"]
    return response(200, { update_available: false })
  end

  # Check rollout percentage
  rollout_pct = (latest["rollout_pct"] || 0).to_i
  if rollout_pct <= 0
    return response(200, { update_available: false })
  end

  # Deterministic rollout bucket
  bucket = Digest::SHA256.hexdigest("#{device_id}:#{latest['version']}").to_i(16) % 100
  if bucket >= rollout_pct
    return response(200, { update_available: false })
  end

  # Step 4: Generate presigned URLs
  s3_key_tarball = latest["s3_key"]
  s3_key_sig = latest["s3_key_sig"]

  presigner = Aws::S3::Presigner.new(client: s3)

  download_url = presigner.presigned_url(
    :get_object,
    bucket: S3_BUCKET,
    key: s3_key_tarball,
    expires_in: PRESIGN_EXPIRY
  )

  sig_url = presigner.presigned_url(
    :get_object,
    bucket: S3_BUCKET,
    key: s3_key_sig,
    expires_in: PRESIGN_EXPIRY
  )

  response(200, {
    update_available: true,
    version: latest["version"],
    download_url: download_url,
    sig_url: sig_url,
    sha256: latest["sha256"],
    release_notes: latest["release_notes"],
  })
end

private

def find_latest_release(dynamodb)
  # Scan for the latest release with rollout > 0
  # For a small releases table, scan is fine. For scale, use a GSI.
  result = dynamodb.scan(
    table_name: RELEASES_TABLE,
    filter_expression: "rollout_pct > :zero",
    expression_attribute_values: { ":zero" => 0 }
  )

  return nil if result.items.empty?

  # Sort by version (semver) and return the latest
  result.items.max_by { |r| Gem::Version.new(r["version"]) }
end

def response(status_code, body)
  {
    statusCode: status_code,
    headers: { "Content-Type" => "application/json" },
    body: JSON.generate(body),
  }
end
