require "json"
require "aws-sdk-dynamodb"
require "aws-sdk-s3"

# register-release Lambda
#
# Triggered by S3 event when a new tarball lands in the releases bucket.
# 1. Extracts version from the S3 key (e.g., v1.3.1/historian-v1.3.1.tar.gz)
# 2. Computes SHA256 of the tarball
# 3. Verifies the .sig file exists alongside it
# 4. Writes a release record to DynamoDB at 0% rollout

RELEASES_TABLE = ENV["RELEASES_TABLE"] || "historian-releases"
S3_BUCKET = ENV["S3_BUCKET"] || "historian-releases"

def handler(event:, context:)
  record = event.dig("Records", 0)
  return unless record

  s3_key = record.dig("s3", "object", "key")
  return unless s3_key&.end_with?(".tar.gz") && !s3_key.end_with?(".tar.gz.sig")

  # Extract version from key: "v1.3.1/historian-v1.3.1.tar.gz" → "1.3.1"
  version = extract_version(s3_key)
  unless version
    puts "Could not extract version from key: #{s3_key}"
    return
  end

  s3 = Aws::S3::Client.new
  dynamodb = Aws::DynamoDB::Client.new

  # Verify the signature file exists
  sig_key = "#{s3_key}.sig"
  begin
    s3.head_object(bucket: S3_BUCKET, key: sig_key)
  rescue Aws::S3::Errors::NotFound
    puts "Signature file not found: #{sig_key}. Skipping registration."
    return
  end

  # Compute SHA256 of the tarball
  sha256 = compute_sha256(s3, S3_BUCKET, s3_key)

  # Write release record to DynamoDB
  dynamodb.put_item(
    table_name: RELEASES_TABLE,
    item: {
      "version" => version,
      "s3_key" => s3_key,
      "s3_key_sig" => sig_key,
      "sha256" => sha256,
      "rollout_pct" => 0,
      "registered_at" => Time.now.utc.iso8601,
    }
  )

  puts "Registered release #{version} (rollout: 0%)"

  { statusCode: 200, body: JSON.generate({ registered: version }) }
end

private

def extract_version(s3_key)
  # "v1.3.1/historian-v1.3.1.tar.gz" → "1.3.1"
  match = s3_key.match(%r{v?([\d]+\.[\d]+\.[\d]+)/})
  match ? match[1] : nil
end

def compute_sha256(s3, bucket, key)
  digest = Digest::SHA256.new

  s3.get_object(bucket: bucket, key: key) do |chunk|
    digest.update(chunk)
  end

  digest.hexdigest
end
