#!/usr/bin/env ruby
# frozen_string_literal: true

# Self-check for sites-cli's HTTP transport (plans/24-agent-sites.md slice 6):
# token/site binding, nonzero conflict exit with no silent 409 retry or
# reread, bounded binary streaming through the media upload API, and no
# bearer token leaking into anything the CLI prints. No test framework -- a
# stub WEBrick server plays the Sites API and asserts on what the CLI
# actually sent and printed.
#
# Run: ruby test_sites_cli.rb

require 'webrick'
# ProcHandler only wires up do_GET/do_POST/do_PUT out of the box; DELETE
# (the abort endpoint, 5b) dispatches through the exact same proc, which
# already branches on req.request_method itself.
WEBrick::HTTPServlet::ProcHandler.alias_method(:do_DELETE, :do_GET)
require 'json'
require 'open3'
require 'tmpdir'
require 'securerandom'

CLI = File.expand_path('sites-cli', __dir__)
FAILURES = []
ALL_OUTPUT = +''

def check(desc)
  yield
  puts "ok - #{desc}"
rescue => e
  FAILURES << "#{desc}: #{e.message}"
  puts "FAIL - #{desc}: #{e.message}"
end

def assert(cond, msg)
  raise msg unless cond
end

TOKEN_ACME  = "TESTTOKEN-ACME-#{SecureRandom.hex(6)}"
TOKEN_OTHER = "TESTTOKEN-OTHER-#{SecureRandom.hex(6)}"

requests = Hash.new(0)                        # "TOKEN tool" => call count
versions = Hash.new { |h, k| h[k] = 'v1' }     # path/label => current "live" version
uploaded = {}                                  # request path => bytes received

# -- multipart video (plans/24-agent-sites.md 5b) stub state ----------------
MP4_PART_SIZE = 10
MP4_PARTS_COUNT = 8
part_attempts = Hash.new(0)                    # part_number => PUT attempts so far
uploaded_parts = {}                            # part_number => bytes received
mutex = Mutex.new
concurrent_parts = 0
max_concurrent_parts = 0
always_fail_part = nil                         # a test arms this to force an unrecoverable part
flaky_part = nil                               # a test arms this to fail once, then succeed

server = nil
port = nil
5.times do
  candidate = 20000 + rand(20000)
  begin
    server = WEBrick::HTTPServer.new(Port: candidate, BindAddress: '127.0.0.1',
      Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    port = candidate
    break
  rescue Errno::EADDRINUSE
    server = nil
  end
end
abort('could not bind a stub server port') unless server

server.mount_proc('/') do |req, res|
  auth = Array(req.header['authorization']).first.to_s
  token = auth.sub(/\ABearer /, '')
  res.content_type = 'application/json'

  case [ req.request_method, req.path ]
  in [ 'POST', '/api/v1/tools' ]
    payload = JSON.parse(req.body)
    tool = payload['tool']
    args = payload['arguments'] || {}
    requests["#{token} #{tool}"] += 1

    case tool
    when 'read_file'
      res.status = 200
      res.body = JSON.generate(version: versions[args['path']], content: 'hello', path: args['path'])
    when 'write_file'
      current = versions[args['path']]
      if args['expected_version'] == current
        versions[args['path']] = "#{current}+"
        res.status = 200
        res.body = JSON.generate(version: versions[args['path']], path: args['path'])
      else
        res.status = 409
        res.body = JSON.generate(error: 'source_changed', path: args['path'], version: current,
          message: 'the live source moved; read it again before writing')
      end
    else
      res.status = 404
      res.body = JSON.generate(error: 'unknown tool in stub')
    end

  in [ 'POST', '/api/v1/media/uploads' ]
    payload = JSON.parse(req.body)
    requests["#{token} media_authorize"] += 1
    current = versions[payload['label']]
    if payload['expected_version'] != current
      res.status = 409
      res.body = JSON.generate(error: 'source_changed', path: payload['label'], version: current, message: 'stale')
    elsif payload['content_type'] == 'video/mp4'
      res.status = 201
      res.body = JSON.generate(id: 'upvideo', status: 'pending', multipart: true,
        parts_count: MP4_PARTS_COUNT, part_size: MP4_PART_SIZE, method: 'PUT', content_type: 'video/mp4')
    else
      res.status = 200
      res.body = JSON.generate(id: 'up1', upload_url: "http://127.0.0.1:#{port}/put/up1")
    end

  in [ 'POST', '/api/v1/media/uploads/up1/complete' ]
    requests["#{token} media_complete"] += 1
    res.status = 200
    res.body = JSON.generate(id: 'up1', status: 'ready', url: 'http://cdn.test/hero.jpg')

  in [ 'GET', '/api/v1/media/uploads/up1' ]
    res.status = 200
    res.body = JSON.generate(id: 'up1', status: 'ready', url: 'http://cdn.test/hero.jpg')

  # -- multipart video (plans/24-agent-sites.md 5b) --------------------------

  in [ 'POST', '/api/v1/media/uploads/upvideo/parts' ]
    payload = JSON.parse(req.body)
    requests["#{token} media_parts"] += 1
    parts = payload['part_numbers'].map { |n| { part_number: n, upload_url: "http://127.0.0.1:#{port}/putpart/#{n}" } }
    res.status = 200
    res.body = JSON.generate(parts: parts)

  in [ 'PUT', String => path ] if path.start_with?('/putpart/')
    part_number = path.split('/').last.to_i
    part_attempts[part_number] += 1
    mutex.synchronize { concurrent_parts += 1; max_concurrent_parts = [ max_concurrent_parts, concurrent_parts ].max }
    sleep 0.05 # widen the window so real parallelism, if any, is observable
    mutex.synchronize { concurrent_parts -= 1 }

    if part_number == always_fail_part
      res.status = 500
    elsif part_number == flaky_part && part_attempts[part_number] == 1
      res.status = 500 # fails once, then succeeds -- exercises part retry
    else
      uploaded_parts[part_number] = req.body
      res['ETag'] = %("part-#{part_number}-etag")
      res.status = 200
    end
    res.body = ''

  in [ 'POST', '/api/v1/media/uploads/upvideo/complete' ]
    requests["#{token} media_complete"] += 1
    res.status = 200
    res.body = JSON.generate(id: 'upvideo', status: 'ready', url: 'http://cdn.test/tour.mp4')

  in [ 'GET', '/api/v1/media/uploads/upvideo' ]
    res.status = 200
    res.body = JSON.generate(id: 'upvideo', status: 'ready', url: 'http://cdn.test/tour.mp4')

  in [ 'DELETE', '/api/v1/media/uploads/upvideo' ]
    requests["#{token} media_abort"] += 1
    res.status = 200
    res.body = JSON.generate(id: 'upvideo', status: 'aborted')

  in [ 'PUT', String => path ] if path.start_with?('/put/')
    uploaded[path] = req.body
    res.content_type = 'text/plain'
    res.status = 200
    res.body = ''

  else
    res.status = 404
    res.body = '{}'
  end
end

Thread.new { server.start }
sleep 0.2 # give WEBrick a moment to bind before the first request

CONFIG_DIR = Dir.mktmpdir('sites-cli-test-')
TOKENS_PATH = File.join(CONFIG_DIR, 'tokens.json')
File.write(TOKENS_PATH, JSON.generate('acme' => TOKEN_ACME, 'other' => TOKEN_OTHER))
File.chmod(0o644, TOKENS_PATH) # deliberately loose -- the CLI must tighten this itself

ENV_OVERRIDES = {
  'SITES_CLI_HOST' => "http://127.0.0.1:#{port}",
  'SITES_CLI_CONFIG_DIR' => CONFIG_DIR
}.freeze

def run_cli(*args)
  out, err, status = Open3.capture3(ENV_OVERRIDES, 'ruby', CLI, *args)
  ALL_OUTPUT << out << err
  [ out, err, status.exitstatus ]
end

# -- token/site binding -----------------------------------------------------

check("read_file authenticates acme with acme's own token") do
  out, _err, code = run_cli('read_file', 'acme', 'foo.md')
  assert(code == 0, "expected exit 0, got #{code}: #{out}")
  assert(requests["#{TOKEN_ACME} read_file"] == 1, "acme's token never reached the server")
end

check("read_file authenticates other with a different token than acme's") do
  out, _err, code = run_cli('read_file', 'other', 'foo.md')
  assert(code == 0, "expected exit 0, got #{code}: #{out}")
  assert(requests["#{TOKEN_OTHER} read_file"] == 1, "other's own token never reached the server")
  assert(requests["#{TOKEN_ACME} read_file"] == 1, 'a call for a different site changed acme call count')
end

check('an unconfigured slug fails locally with no HTTP request at all') do
  before = requests.values.sum
  out, _err, code = run_cli('read_file', 'ghost', 'foo.md')
  assert(code != 0, 'expected nonzero exit for an unconfigured slug')
  assert(JSON.parse(out)['code'] == 'NO_TOKEN', "expected NO_TOKEN, got #{out}")
  assert(requests.values.sum == before, 'a request reached the stub server for a slug with no token')
end

check('tokens.json permissions are tightened to 0600 on first use') do
  run_cli('read_file', 'acme', 'perm-check.md')
  mode = File.stat(TOKENS_PATH).mode & 0o777
  assert(mode == 0o600, "expected 0600, got #{mode.to_s(8)}")
end

# -- conflict: nonzero exit, no silent retry, no silent reread ---------------

check('write_file with a stale cached version conflicts, exits nonzero, preserves the 409 body') do
  run_cli('read_file', 'acme', 'stale.md') # caches version v1
  versions['stale.md'] = 'v5' # simulate someone else editing it after our read

  before = requests["#{TOKEN_ACME} write_file"]
  out, _err, code = run_cli('write_file', 'acme', 'stale.md', '--content', 'new text')
  parsed = JSON.parse(out)

  assert(code != 0, 'expected nonzero exit on a 409')
  assert(parsed['ok'] == false, 'expected ok:false')
  assert(parsed['status'] == 409, "expected the real HTTP status preserved, got #{parsed['status'].inspect}")
  assert(parsed.dig('body', 'error') == 'source_changed', "expected the structured conflict kind, got #{parsed['body'].inspect}")
  assert(parsed.dig('body', 'version') == 'v5', "expected the server's current version in the preserved body")
  assert(requests["#{TOKEN_ACME} write_file"] == before + 1, 'expected exactly one write_file request, no automatic retry')
end

check('a second run without an explicit re-read repeats the same conflict instead of quietly succeeding') do
  out, _err, code = run_cli('write_file', 'acme', 'stale.md', '--content', 'new text again')
  assert(code != 0, 'a write never preceded by a fresh read must keep failing, not silently reread and succeed')
  assert(JSON.parse(out)['status'] == 409, 'expected the same conflict again')
end

check('an explicit re-read picks up the new version, and the next write then succeeds') do
  run_cli('read_file', 'acme', 'stale.md') # a real re-read; now caches v5
  out, _err, code = run_cli('write_file', 'acme', 'stale.md', '--content', 'final text')
  assert(code == 0, "expected success once the cache matches the live version, got: #{out}")
end

# -- bounded binary streaming -------------------------------------------------

check('put_upload streams from disk (body_stream), not a buffered read into memory') do
  source = File.read(CLI)
  assert(source.include?('req.body_stream ='), 'expected the presigned PUT to stream the file, not buffer it')
  refute = !source.match?(/req\.body\s*=\s*File\.(read|binread)/)
  assert(refute, 'found the PUT body assigned from a fully-read file instead of a stream')
end

check('write_file --file round-trips a multi-megabyte binary upload byte-for-byte') do
  run_cli('read_file', 'acme', 'assets/hero.jpg') # caches v1 for the upload label

  Dir.mktmpdir do |dir|
    photo_path = File.join(dir, 'hero.jpg')
    original = SecureRandom.random_bytes(3 * 1024 * 1024)
    File.binwrite(photo_path, original)

    out, _err, code = run_cli('write_file', 'acme', 'assets/hero.jpg', '--file', photo_path)
    assert(code == 0, "expected a successful upload, got: #{out}")
    assert(uploaded['/put/up1'] == original, 'uploaded bytes did not match the source file byte-for-byte')
  end
end

# -- multipart video: part retry, bounded parallelism, abort (5b) -----------

check('write_file --file for an .mp4 uploads via multipart and round-trips bytes across parts') do
  run_cli('read_file', 'acme', 'assets/tour.mp4')
  before_completes = requests["#{TOKEN_ACME} media_complete"]

  Dir.mktmpdir do |dir|
    video_path = File.join(dir, 'tour.mp4')
    original = SecureRandom.random_bytes(MP4_PART_SIZE * MP4_PARTS_COUNT)
    File.binwrite(video_path, original)

    out, _err, code = run_cli('write_file', 'acme', 'assets/tour.mp4', '--file', video_path)
    assert(code == 0, "expected a successful multipart upload, got: #{out}")

    reassembled = (1..MP4_PARTS_COUNT).map { |n| uploaded_parts.fetch(n) }.join
    assert(reassembled == original, 'reassembled part bytes did not match the source file byte-for-byte')
    assert(requests["#{TOKEN_ACME} media_complete"] == before_completes + 1, 'expected exactly one complete call')
  end
end

check('a part that fails once is retried with a fresh presign, not treated as an unrecoverable failure') do
  run_cli('read_file', 'acme', 'assets/tour.mp4') # the stub never advances this label's version
  part_attempts.clear
  flaky_part = 4

  Dir.mktmpdir do |dir|
    video_path = File.join(dir, 'retry.mp4')
    File.binwrite(video_path, SecureRandom.random_bytes(MP4_PART_SIZE * MP4_PARTS_COUNT))

    out, _err, code = run_cli('write_file', 'acme', 'assets/tour.mp4', '--file', video_path)
    assert(code == 0, "expected the retried part to eventually succeed, got: #{out}")
  end

  assert(part_attempts[4] == 2, "expected part 4 to be attempted twice, got #{part_attempts[4]}")
ensure
  flaky_part = nil
end

check('parts upload with bounded parallelism -- more than one at a time, never unbounded') do
  run_cli('read_file', 'acme', 'assets/tour.mp4')
  max_concurrent_parts = 0

  Dir.mktmpdir do |dir|
    video_path = File.join(dir, 'parallel.mp4')
    File.binwrite(video_path, SecureRandom.random_bytes(MP4_PART_SIZE * MP4_PARTS_COUNT))
    out, _err, code = run_cli('write_file', 'acme', 'assets/tour.mp4', '--file', video_path)
    assert(code == 0, "expected success, got: #{out}")
  end

  assert(max_concurrent_parts > 1, "expected real parallelism, saw max #{max_concurrent_parts} at once")
  assert(max_concurrent_parts <= 4, "expected parallelism bounded to 4 workers, saw #{max_concurrent_parts}")
end

check('an unrecoverable part failure gives up after bounded retries and aborts the upload') do
  run_cli('read_file', 'acme', 'assets/tour.mp4')
  always_fail_part = 2
  part_attempts.clear
  before_abort_calls = requests["#{TOKEN_ACME} media_abort"]

  Dir.mktmpdir do |dir|
    video_path = File.join(dir, 'doomed.mp4')
    File.binwrite(video_path, SecureRandom.random_bytes(MP4_PART_SIZE * MP4_PARTS_COUNT))
    out, _err, code = run_cli('write_file', 'acme', 'assets/tour.mp4', '--file', video_path)
    assert(code != 0, 'expected a nonzero exit once a part cannot be uploaded')
    assert(JSON.parse(out)['code'] == 'PART_UPLOAD_FAILED', "expected PART_UPLOAD_FAILED, got: #{out}")
  end

  assert(part_attempts[2] == 3, "expected exactly 3 bounded attempts, got #{part_attempts[2]}")
  assert(requests["#{TOKEN_ACME} media_abort"] == before_abort_calls + 1, 'expected the CLI to abort after giving up')
ensure
  always_fail_part = nil
end

# -- secret redaction ---------------------------------------------------------

check('no bearer token ever appears in anything the CLI printed') do
  refute_acme  = !ALL_OUTPUT.include?(TOKEN_ACME)
  refute_other = !ALL_OUTPUT.include?(TOKEN_OTHER)
  assert(refute_acme, "acme's token leaked into CLI output")
  assert(refute_other, "other's token leaked into CLI output")
end

server.shutdown

if FAILURES.empty?
  puts "\nAll checks passed."
  exit 0
else
  puts "\n#{FAILURES.size} failure(s):"
  FAILURES.each { |f| puts "  - #{f}" }
  exit 1
end
