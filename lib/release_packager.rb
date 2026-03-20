require "yaml"
require "json"
require "time"
require "digest"
require "fileutils"
require "shellwords"
require "open3"

# ReleasePackager — builds, signs, and uploads Historian release packages.
#
# Runs on the dev Mac. Packages the deploy repo's own contents into
# a signed tarball and uploads to S3.
#
# Usage:
#   packager = ReleasePackager.new(version: "1.3.1")
#   packager.build        # create tarball + manifest
#   packager.sign         # Ed25519 sign
#   packager.upload       # push to S3
#
class ReleasePackager
  SIGNING_KEY_PATH = File.expand_path("~/.historian/update-signing.key")
  DEPLOY_ROOT = File.dirname(File.expand_path(__FILE__), 2)
  DEV_REPO = File.join(File.dirname(DEPLOY_ROOT), "historian")
  BUILD_DIR = File.join(DEPLOY_ROOT, "tmp", "release")

  # Files/dirs excluded from the tarball (dev-only, not needed on device)
  EXCLUDES = %w[
    .git
    .gitignore
    spec
    tmp
    lambda
    bin/hist-release
    lib/release_packager.rb
    *.tar.gz
    *.sig
  ].freeze

  attr_reader :version, :dry_run

  def initialize(version: nil, dry_run: false, skip_upload: false, min_version: nil)
    @version = version || read_version
    @dry_run = dry_run
    @skip_upload = skip_upload
    @min_version = min_version || "1.0.0"
    @tarball_name = "historian-v#{@version}.tar.gz"
    @sig_name = "#{@tarball_name}.sig"
  end

  # Full release pipeline
  def release!
    header "Historian Release Packager"
    puts "   Version:  #{@version}"
    puts "   Source:   #{dev_repo_commit || 'unknown'} (#{DEV_REPO})"
    puts "   Mode:     #{@dry_run ? 'DRY RUN' : 'LIVE'}"
    puts ""

    tag_dev_repo
    build
    sign
    upload unless @skip_upload

    puts ""
    header "✅ RELEASE COMPLETE"
    puts "   Package:  #{@tarball_name}"
    puts "   Source:   #{DEV_REPO} @ v#{@version}"
    puts "   Uploaded: #{@skip_upload ? 'no (--skip-upload)' : "s3://historian-releases/v#{@version}/"}"
    puts "   Rollout:  0% (use 'hist-release rollout #{@version} --percent 10' to roll out)"
    puts ""
  end

  # --- Step 1: Build tarball ---

  def build
    step "Building release package"

    # Clean build dir
    FileUtils.rm_rf(BUILD_DIR)
    FileUtils.mkdir_p(BUILD_DIR)

    staging = File.join(BUILD_DIR, "historian-deploy")
    FileUtils.mkdir_p(staging)

    # Collect files
    files = collectible_files
    step "Packaging #{files.length} files"

    # Copy files to staging
    files.each do |relative_path|
      src = File.join(DEPLOY_ROOT, relative_path)
      dest = File.join(staging, relative_path)
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp(src, dest)
    end

    # Compute per-file checksums
    checksums = {}
    files.each do |relative_path|
      file_path = File.join(staging, relative_path)
      checksums[relative_path] = "sha256:#{Digest::SHA256.file(file_path).hexdigest}"
    end

    # Generate update_manifest.yml
    manifest = {
      "version" => @version,
      "min_version" => @min_version,
      "built_at" => Time.now.utc.iso8601,
      "deploy_repo_commit" => git_commit,
      "source_repo" => {
        "path" => DEV_REPO,
        "commit" => dev_repo_commit,
        "tag" => "v#{@version}",
      },
      "release_notes" => "",
      "hooks" => {
        "pre_deploy" => nil,
        "post_deploy" => nil,
      },
      "checksums" => checksums,
    }

    manifest_path = File.join(staging, "update_manifest.yml")
    File.write(manifest_path, YAML.dump(manifest))
    step "Generated update_manifest.yml (#{checksums.size} checksums)"

    # Create tarball
    tarball_path = File.join(BUILD_DIR, @tarball_name)
    Dir.chdir(BUILD_DIR) do
      system("tar czf #{Shellwords.escape(@tarball_name)} historian-deploy/")
    end

    size_kb = (File.size(tarball_path) / 1024.0).round(1)
    step "Created #{@tarball_name} (#{size_kb}KB)"

    tarball_path
  end

  # --- Step 2: Sign ---

  def sign
    tarball_path = File.join(BUILD_DIR, @tarball_name)
    sig_path = File.join(BUILD_DIR, @sig_name)

    if @dry_run
      step "[DRY RUN] Would sign #{@tarball_name}"
      return sig_path
    end

    unless File.exist?(SIGNING_KEY_PATH)
      abort "❌ Signing key not found: #{SIGNING_KEY_PATH}\n" \
            "   Generate with: openssl genpkey -algorithm ed25519 -out #{SIGNING_KEY_PATH}"
    end

    step "Signing with Ed25519"

    cmd = "openssl pkeyutl -sign " \
          "-inkey #{Shellwords.escape(SIGNING_KEY_PATH)} " \
          "-rawin -in #{Shellwords.escape(tarball_path)} " \
          "-out #{Shellwords.escape(sig_path)}"

    unless system(cmd)
      abort "❌ Signing failed"
    end

    step "Signature: #{@sig_name}"
    sig_path
  end

  # --- Step 3: Upload to S3 ---

  def upload
    tarball_path = File.join(BUILD_DIR, @tarball_name)
    sig_path = File.join(BUILD_DIR, @sig_name)
    s3_prefix = "v#{@version}"

    step "Uploading to s3://historian-releases/#{s3_prefix}/"

    if @dry_run
      step "[DRY RUN] Would upload #{@tarball_name} + #{@sig_name}"
      return
    end

    run("aws s3 cp #{Shellwords.escape(tarball_path)} s3://historian-releases/#{s3_prefix}/#{@tarball_name}")
    run("aws s3 cp #{Shellwords.escape(sig_path)} s3://historian-releases/#{s3_prefix}/#{@sig_name}")

    step "Upload complete"
  end

  # --- Rollout control ---

  def self.rollout(version, percent)
    puts "Setting rollout for v#{version} to #{percent}%"

    cmd = "aws dynamodb update-item " \
          "--table-name historian-releases " \
          "--key '{\"version\": {\"S\": \"#{version}\"}}' " \
          "--update-expression 'SET rollout_pct = :p' " \
          "--expression-attribute-values '{\":p\": {\"N\": \"#{percent}\"}}'"

    unless system(cmd)
      abort "❌ Failed to update rollout. Is the AWS CLI configured?"
    end

    if percent.to_i == 0
      puts "🛑 Rollout halted for v#{version}"
    else
      puts "✅ v#{version} rolling out to #{percent}% of fleet"
    end
  end

  private

  def collectible_files
    all_files = Dir.glob("**/*", File::FNM_DOTMATCH, base: DEPLOY_ROOT)
      .reject { |f| File.directory?(File.join(DEPLOY_ROOT, f)) }

    all_files.reject do |f|
      EXCLUDES.any? do |pattern|
        f == pattern ||
          f.start_with?("#{pattern}/") ||
          File.fnmatch(pattern, f) ||
          File.fnmatch(pattern, File.basename(f))
      end
    end
  end

  def read_version
    version_file = File.join(DEPLOY_ROOT, "VERSION")
    if File.exist?(version_file)
      File.read(version_file).strip
    else
      abort "❌ VERSION file not found"
    end
  end

  def git_commit
    `git -C #{Shellwords.escape(DEPLOY_ROOT)} rev-parse --short HEAD 2>/dev/null`.strip
  rescue
    "unknown"
  end

  def dev_repo_commit
    return nil unless Dir.exist?(DEV_REPO)
    `git -C #{Shellwords.escape(DEV_REPO)} rev-parse --short HEAD 2>/dev/null`.strip
  rescue
    nil
  end

  def tag_dev_repo
    tag = "v#{@version}"

    unless Dir.exist?(DEV_REPO)
      step "⚠️  Dev repo not found at #{DEV_REPO} — skipping tag"
      return
    end

    # Check for uncommitted changes
    status = `git -C #{Shellwords.escape(DEV_REPO)} status --porcelain 2>/dev/null`.strip
    unless status.empty?
      step "⚠️  Dev repo has uncommitted changes — tag will mark current HEAD"
    end

    if @dry_run
      step "[DRY RUN] Would tag #{DEV_REPO} as #{tag}"
      return
    end

    # Create annotated tag
    sha = dev_repo_commit
    cmd = "git -C #{Shellwords.escape(DEV_REPO)} tag -a #{tag} -m 'Release #{@version}' 2>&1"
    output, success = Open3.capture2e(cmd)

    if success.success?
      step "Tagged dev repo: #{tag} (#{sha})"
    elsif output.include?("already exists")
      step "Tag #{tag} already exists in dev repo (#{sha})"
    else
      step "⚠️  Failed to tag dev repo: #{output.strip}"
    end
  end

  def run(cmd)
    puts "     $ #{cmd}"
    unless system(cmd)
      abort "❌ Command failed: #{cmd}"
    end
  end

  def header(text)
    puts ""
    puts "═" * 60
    puts "  #{text}"
    puts "═" * 60
    puts ""
  end

  def step(text)
    puts "   ✦ #{text}"
  end
end
