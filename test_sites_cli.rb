#!/usr/bin/env ruby
# frozen_string_literal: true

# Self-check for sites-cli's HTTP transport: token/site binding, nonzero
# conflict exit with no silent 409 retry or reread, bounded binary streaming
# through the media upload API, the plan 30 v2 tool request shapes, expected
# token persistence, upload content types and parallelism, push change-list
# generation, the agent-browser `check` wrapper, and no bearer token leaking
# into anything the CLI prints. No test framework -- a stub WEBrick server
# plays the Sites API and asserts on what the CLI actually sent and printed.
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
require 'digest'
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
TOKEN_ONYX  = "TESTTOKEN-ONYX-#{SecureRandom.hex(6)}"
# A personal token is the credential the platform door takes (slice F), and
# since the personal-door change it opens the site doors too, as long as the
# request names the site.
TOKEN_USER  = "sk_user_42_#{SecureRandom.hex(6)}"

requests = Hash.new(0)                        # "TOKEN tool" => call count
last_args = {}                                 # tool => the last arguments hash
last_envelope = {}                             # tool => the whole request body
media_sites = []                               # the site field/query on every media request
site_on_site_token = []                        # site-token requests that carried a site field
versions = Hash.new { |h, k| h[k] = 'v1' }     # path/label => current "live" version
uploaded = {}                                  # request path => bytes received

# -- versioned (plan 30) stub state -----------------------------------------
branch_heads = { 'draft' => 'snap_head0', 'live' => 'snap_live0' }
# The stub plays one versioned site (onyx) for a site token, plus whatever
# `create_site` made for a personal one -- so a save right after a create-site
# CASes against that new site's own draft head, not onyx's.
new_site_heads = {}                            # slug => {branch => head}
bound_assets = {}                              # "branch:key" => digest bound on that branch
publications = 0
preview_queue = []                             # statuses wait-preview walks through
fail_batch_read = false                        # a test arms this to play a pre-slice-E server
authorized = {}                                # upload id => the authorize payload
upload_seq = 0
put_mutex = Mutex.new
concurrent_puts = 0
max_concurrent_puts = 0
fail_upload_named = nil                        # a test arms this to break one file
# The platform is content addressed: once it holds a digest, a later authorize
# for the same bytes answers `ready` with the blob URL and NO upload_url. That
# fast path used to crash the CLI (pc_60d7aa4c, pc_e3810da4, pc_c3606ecf).
known_digests = {}                             # digest => {media_type, byte_size}
authorize_bodies = []                          # every label-less authorize payload, in order
weird_authorize = nil                          # a test arms this to answer a shape nothing expects
multipart_named = nil                          # a test arms this to force the multipart transport
multipart_upa = nil                            # the upload id that took it
BIG_PART_SIZE = 12
BIG_PARTS_COUNT = 3
big_parts = {}                                 # part_number => bytes received

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

def next_head(current)
  "snap_#{Digest::SHA256.hexdigest(current)[0, 12]}"
end

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
    last_args[tool] = args
    last_envelope[tool] = payload
    heads = new_site_heads[payload['site']] || branch_heads

    # The contract in both directions. A personal token carries a person, so
    # the request has to say which site -- naming none is the real server's
    # 403. A site token carries its site, so a `site` field there would be a
    # changed request shape; every one is recorded and asserted away at the end.
    if token.start_with?('sk_user_')
      if payload['site'].nil?
        res.status = 403
        res.body = JSON.generate(error: 'capability_denied', field: 'site',
          message: 'a personal token needs `site` in the request; site tokens carry their site')
        next
      end
    elsif payload.key?('site')
      site_on_site_token << "#{tool} #{payload['site'].inspect}"
    end

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

    # -- plan 30 versioned tools --------------------------------------------

    when 'describe_site'
      # acme is the legacy site throughout this file. A legacy describe_site
      # answers a shape with no `versioned` and no `branches` -- and refuses a
      # `branch` argument outright rather than ignoring it (slice F N9), which
      # is why nothing may send one before it knows the contract.
      if token == TOKEN_ACME && args['path'].nil?
        if args['branch']
          res.status = 422
          res.body = JSON.generate(error: 'invalid_request',
            message: 'branch is a versioned argument; acme still uses the file API, where path is the target',
            site: 'acme', next: { tool: 'describe_site', why: 'call it with no branch, or with a path' })
        else
          res.status = 200
          res.body = JSON.generate(site: 'acme', url: 'https://acme.gxbsites.com',
            permissions: %w[read draft], pending: { pages: 0, design: false }, files: [])
        end
        next
      end
      status = preview_queue.empty? ? 'queued' : preview_queue.shift
      res.status = 200
      res.body = JSON.generate(
        site: 'onyx', name: 'Onyx', versioned: true, restricted: false,
        capabilities: %w[draft publish read],
        live: nil,
        branches: branch_heads.reject { |name, _| name == 'live' }.map { |name, head|
          { name: name, expected: head, preview_status: status,
            preview_url: "https://abcdefghijklmn-onyx.gxbsites.com", diagnostics: [], review: "rev_#{head}" }
        },
        pending: { branch: args['branch'] || 'draft', against: 'live', keys: 1, truncated: false })
    when 'read'
      branch = args['branch'] || 'draft'
      # A historical read answers with the snapshot it read, not a branch head
      # CAS token (slice E). The batch asset form answers {key => digest} for
      # the bound ones and simply omits the rest.
      expected = args['at'] || heads[branch]
      if args['kind'] == 'asset' && args['keys']
        if fail_batch_read
          res.status = 404
          res.body = JSON.generate(error: 'not_found', message: 'unknown tool argument: keys')
        else
          digests = args['keys'].to_h { |k| [ k, bound_assets["#{branch}:#{k}"] ] }.compact
          res.status = 200
          res.body = JSON.generate(kind: 'asset', branch: branch, expected: expected,
            digests: digests, keys: args['keys'].size)
        end
      else
        res.status = 200
        res.body = JSON.generate(kind: args['kind'], key: args['key'], branch: branch,
          at: args['at'], expected: expected, digest: 'a' * 64, format: 'html',
          metadata: { 'title' => 'Home' }, body: '<p>one</p>')
      end
    when 'archive_branch'
      res.status = 200
      res.body = JSON.generate(site: 'onyx', branch: args['name'], archived: true,
        archived_at: '2026-09-21T04:20:00Z', expected: branch_heads[args['name']] || 'snap_head0')
    when 'save'
      branch = args['branch'] || 'draft'
      current = heads[branch]
      if args['expected'] == current
        heads[branch] = next_head(current)
        Array(args['changes']).each do |c|
          bound_assets["#{branch}:#{c['key']}"] = c['digest'] if c['kind'] == 'asset' && c['op'] == 'put'
        end
        res.status = 200
        # A fresh snapshot has no ready build yet, so `review` is an explicit
        # null (slice D's save payload), which must drop any remembered one.
        res.body = JSON.generate(site: payload['site'] || 'onyx', branch: branch, expected: heads[branch],
          snapshot_created: true, changed_keys: Array(args['changes']).map { |c| "#{c['kind']}:#{c['key']}" },
          preview_status: 'queued', preview_url: 'https://abcdefghijklmn-onyx.gxbsites.com',
          review: nil)
      else
        res.status = 409
        res.body = JSON.generate(error: 'branch_changed', path: nil, version: nil,
          message: "#{branch} moved since you read it; reread the keys you are changing before retrying",
          branch: branch, expected: current,
          next: { tool: 'describe_site', arguments: { branch: branch } })
      end
    when 'create_branch'
      source = args['from'] || 'live'
      head = branch_heads[source] || branch_heads['live']
      branch_heads[args['name']] = head
      res.status = 200
      res.body = JSON.generate(site: 'onyx', branch: args['name'], from: source,
        expected: head, snapshot_created: false)
    when 'diff'
      branch = args['branch'] || 'draft'
      res.status = 200
      res.body = JSON.generate(site: 'onyx', branch: branch, against: args['against'] || 'live',
        expected: branch_heads[branch], changes: { pages: { added: [ '/about' ] } }, keys: 1, truncated: false)
    when 'publish'
      if args['review']
        publications += 1
        res.status = 200
        res.body = JSON.generate(published: true, publication: publications,
          live_url: 'https://onyx.gxbsites.com', cache_convergence_seconds: 60)
      elsif args['keys']
        branch = args['branch'] || 'draft'
        res.status = 200
        res.body = JSON.generate(published: false, review: 'rev_subset', site: 'onyx',
          branch: branch, expected: branch_heads[branch],
          preview_url: 'https://abcdefghijklmn-onyx.gxbsites.com', preview_status: 'queued',
          included: args['keys'], left_on_branch: [ 'page:/' ])
      elsif args['path']
        res.status = 200
        res.body = JSON.generate(path: args['path'], published: true)
      else
        res.status = 422
        res.body = JSON.generate(error: 'invalid_request', message: 'publish needs review or keys')
      end
    when 'merge_live'
      branch = args['branch'] || 'draft'
      branch_heads[branch] = next_head(branch_heads[branch])
      res.status = 200
      res.body = JSON.generate(site: 'onyx', branch: branch, expected: branch_heads[branch],
        merged: true, fast_forwarded: false, review: "rev_#{branch_heads[branch]}")
    when 'resolve_merge'
      branch_heads['draft'] = next_head(branch_heads['draft'])
      res.status = 200
      res.body = JSON.generate(site: 'onyx', branch: 'draft', expected: branch_heads['draft'], resolved: true)
    when 'history'
      res.status = 200
      res.body = JSON.generate(site: 'onyx', branch: args['branch'] || 'draft',
        snapshots: [ { snapshot: 'snap_head0', message: 'first', actor: 'agent', created_at: '2026-09-20T00:00:00Z' } ])
    when 'revoke_preview'
      res.status = 200
      res.body = JSON.generate(revoked: true, preview_url: args['preview_url'], token: args['token'])
    when 'list_sites'
      res.status = 200
      res.body = JSON.generate(sites: [ { slug: 'onyx', name: 'Onyx', versioned: true } ])
    when 'list_submissions'
      if token == TOKEN_ONYX
        res.status = 200
        res.body = JSON.generate(site: 'onyx', submissions: [ { id: 4, form: args['form_slug'] || 'customer',
          created_at: '2026-09-21T08:00:00Z', data: { name: 'Slice G Test' } } ], count: 1)
      else
        # what a token minted before read_submissions became its own capability gets
        res.status = 403
        res.body = JSON.generate(error: 'capability_denied', capability: 'read_submissions',
          site: 'acme', message: 'list_submissions needs the read_submissions capability; this token carries read, draft')
      end
    when 'get_analytics'
      res.status = 200
      res.body = JSON.generate(site: 'onyx', period: args['period'] || '7d', visitors: 12, pageviews: 30)
    when 'create_site'
      res.status = 403
      res.body = JSON.generate(error: 'capability_denied', capability: 'create_site',
        message: 'create_site needs a signed-in GXB staff account, not a site-bound token')
    else
      res.status = 404
      res.body = JSON.generate(error: 'unknown tool in stub')
    end

  # -- the platform door: a personal token only (slice F section 4) ----------
  in [ 'POST', '/api/v1/platform/tools' ]
    payload = JSON.parse(req.body)
    tool = payload['tool']
    args = payload['arguments'] || {}
    requests["#{token} platform:#{tool}"] += 1
    last_args["platform:#{tool}"] = args

    if !token.start_with?('sk_user_')
      res.status = 403
      res.body = JSON.generate(error: 'capability_denied',
        message: 'this endpoint takes a personal token minted from your profile on sites.gxb.vc, not a site token')
    else
      case tool
      when 'list_sites'
        res.status = 200
        res.body = JSON.generate(sites: [
          { slug: 'onyx', name: 'Onyx', url: 'https://onyx.gxbsites.com', versioned: true, capabilities: %w[draft publish read] },
          { slug: 'acme', name: 'Acme', url: 'https://acme.gxbsites.com', versioned: false, capabilities: %w[read] }
        ])
      when 'create_site'
        # The new site's draft head lives in its own map, so the very next
        # save for that slug CASes against this token and needs no describe in
        # between -- which is the whole point of one credential for the flow.
        new_site_heads[args['slug']] = { 'draft' => 'snap_newsite0' }
        res.status = 200
        res.body = JSON.generate(site: args['slug'], name: args['name'],
          url: "https://#{args['slug']}.gxbsites.com", versioned: true,
          branch: 'draft', expected: 'snap_newsite0', capabilities: %w[draft publish read])
      else
        res.status = 404
        res.body = JSON.generate(error: 'unknown_tool', message: "#{tool.inspect} is not a platform tool",
          tools: %w[create_site list_sites])
      end
    end

  in [ 'GET', '/api/v1/platform/tools' ]
    requests["#{token} platform:index"] += 1
    if token.start_with?('sk_user_')
      res.status = 200
      res.body = JSON.generate(tools: [ { name: 'list_sites' }, { name: 'create_site' } ])
    else
      res.status = 403
      res.body = JSON.generate(error: 'capability_denied', message: 'not a personal token')
    end

  in [ 'GET', '/cors/blocked.js' ]
    # 200, and deliberately no access-control-allow-origin: a real bucket-CORS
    # failure, which is indistinguishable from a 404 inside the browser.
    requests['cors_probe'] += 1
    res.status = 200
    res.content_type = 'text/javascript'
    res.body = 'export const a = 1'

  in [ 'POST', '/api/v1/media/uploads' ]
    payload = JSON.parse(req.body)
    requests["#{token} media_authorize"] += 1
    media_sites << payload['site'] if token.start_with?('sk_user_')
    site_on_site_token << "media_authorize #{payload['site'].inspect}" if !token.start_with?('sk_user_') && payload.key?('site')

    if payload['label'].nil?
      # plan 30: no label, no expected_version -- filename and digest only.
      upload_seq += 1
      id = "upa#{upload_seq}"
      authorized[id] = payload
      authorize_bodies << payload
      held = known_digests[payload['digest']]
      if weird_authorize
        res.status = 200
        res.body = JSON.generate(id: id, status: 'contemplating')
      elsif payload['content_type'].to_s.start_with?('text/html')
        # The one refusal left: a page hosted as a blob would be phishing on
        # cdn.gxbsites.com (uploads brief item 2).
        res.status = 422
        res.body = JSON.generate(error: 'unsupported_content_type',
          message: 'text/html is refused: a page belongs in a page document, not a blob on the asset CDN')
      elsif held
        # No upload_url at all: the bytes are already here.
        res.status = 200
        res.body = JSON.generate(id: id, status: 'ready', digest: payload['digest'],
          media_type: held[:media_type], byte_size: held[:byte_size],
          url: "http://cdn.test/blobs/#{payload['digest']}/asset.bin")
      elsif payload['filename'] == multipart_named
        # Over 25 MB the server asks for the multipart transport whatever the
        # type is (uploads brief item 2). The CLI follows `multipart`, so the
        # threshold is the server's to pick; this proves the CLI follows it for
        # a kind that used to be single-PUT only.
        multipart_upa = id
        res.status = 201
        res.body = JSON.generate(id: id, status: 'pending', multipart: true,
          parts_count: BIG_PARTS_COUNT, part_size: BIG_PART_SIZE)
      else
        res.status = 201
        res.body = JSON.generate(id: id, status: 'pending', upload_url: "http://127.0.0.1:#{port}/put/#{id}")
      end
    else
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

  # -- plan 30 label-less uploads -------------------------------------------

  in [ 'POST', String => path ] if path =~ %r{\A/api/v1/media/uploads/(upa\d+)/parts\z}
    payload = JSON.parse(req.body)
    requests["#{token} media_parts"] += 1
    res.status = 200
    res.body = JSON.generate(parts: payload['part_numbers'].map { |n|
      { part_number: n, upload_url: "http://127.0.0.1:#{port}/putbig/#{n}" } })

  in [ 'PUT', String => path ] if path.start_with?('/putbig/')
    part_number = path.split('/').last.to_i
    big_parts[part_number] = req.body
    res['ETag'] = %("big-#{part_number}-etag")
    res.status = 200
    res.body = ''

  in [ 'POST', String => path ] if path =~ %r{\A/api/v1/media/uploads/(upa\d+)/complete\z}
    id = Regexp.last_match(1)
    requests["#{token} media_complete"] += 1
    media_sites << JSON.parse(req.body)['site'] if token.start_with?('sk_user_')
    payload = authorized.fetch(id)
    digest = payload['digest']
    # The platform types bytes from content, not from the filename: a file
    # called .png holding JPEG bytes is stored and served as image/jpeg.
    media_type = uploaded["/put/#{id}"].to_s.start_with?("\xFF\xD8\xFF".b) ? 'image/jpeg' : payload['content_type']
    known_digests[digest] = { media_type: media_type, byte_size: payload['byte_size'] }
    res.status = 200
    res.body = JSON.generate(id: id, status: 'ready', digest: digest,
      media_type: media_type, byte_size: payload['byte_size'],
      url: "http://cdn.test/blobs/#{digest}/asset.bin", version: id)

  in [ 'GET', String => path ] if path =~ %r{\A/api/v1/media/uploads/(upa\d+)\z}
    id = Regexp.last_match(1)
    # A GET has no body, so a personal token names the site in the query.
    media_sites << req.query['site'] if token.start_with?('sk_user_')
    payload = authorized.fetch(id)
    res.status = 200
    res.body = JSON.generate(id: id, status: 'ready', digest: payload['digest'],
      media_type: payload['content_type'], byte_size: payload['byte_size'],
      url: "http://cdn.test/blobs/#{payload['digest']}/asset.bin")

  in [ 'PUT', String => path ] if path.start_with?('/put/')
    if path.start_with?('/put/upa')
      put_mutex.synchronize { concurrent_puts += 1; max_concurrent_puts = [ max_concurrent_puts, concurrent_puts ].max }
      sleep 0.05
      put_mutex.synchronize { concurrent_puts -= 1 }
    end
    id = path.split('/').last
    if fail_upload_named && authorized.dig(id, 'filename') == fail_upload_named
      res.status = 500
    else
      uploaded[path] = req.body
      res.status = 200
    end
    res.content_type = 'text/plain'
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
STATE_PATH = File.join(CONFIG_DIR, 'state.json')
File.write(TOKENS_PATH, JSON.generate('acme' => TOKEN_ACME, 'other' => TOKEN_OTHER, 'onyx' => TOKEN_ONYX))
File.chmod(0o644, TOKENS_PATH) # deliberately loose -- the CLI must tighten this itself

ENV_OVERRIDES = {
  'SITES_CLI_HOST' => "http://127.0.0.1:#{port}",
  'SITES_CLI_CONFIG_DIR' => CONFIG_DIR,
  # nil unsets it in the child: a personal token in the developer's own shell
  # would otherwise become a silent fallback and change what these checks mean.
  'SITES_CLI_TOKEN' => nil
}.freeze

def run_cli(*args, env: {}, stdin: nil)
  out, err, status = Open3.capture3(ENV_OVERRIDES.merge(env), 'ruby', CLI, *args, stdin_data: stdin.to_s)
  ALL_OUTPUT << out << err
  [ out, err, status.exitstatus ]
end

def state = JSON.parse(File.read(STATE_PATH))

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

# =============================================================================
# plan 30 v2 subcommands
# =============================================================================

check('describe posts describe_site and remembers every branch head token') do
  out, _err, code = run_cli('describe', 'onyx')
  assert(code == 0, "expected exit 0, got #{code}: #{out}")
  assert(JSON.parse(out).dig('data', 'versioned') == true, "expected the raw {ok, data} envelope, got: #{out}")
  assert(state['expected:onyx:draft'] == branch_heads['draft'],
    "expected the draft head remembered, state has #{state['expected:onyx:draft'].inspect}")
end

check('describe still passes a legacy PATH argument through untouched') do
  run_cli('describe_site', 'onyx', 'about.md')
  assert(last_args['describe_site'] == { 'path' => 'about.md' }, "got #{last_args['describe_site'].inspect}")
end

check('read posts the v2 read tool with kind, key, fields, lines, at and branch') do
  out, _err, code = run_cli('read', 'onyx', 'page', '/about', '--fields', 'metadata,body',
                            '--lines', '2,40', '--at', 'snap_old1', '--branch', 'draft')
  assert(code == 0, "expected exit 0, got #{code}: #{out}")
  assert(last_args['read'] == { 'kind' => 'page', 'key' => '/about', 'branch' => 'draft',
                                'fields' => %w[metadata body], 'lines' => [ 2, 40 ], 'at' => 'snap_old1' },
    "got #{last_args['read'].inspect}")
end

check('a historical read never becomes the remembered branch head') do
  run_cli('describe', 'onyx')
  head = state['expected:onyx:draft']
  run_cli('read', 'onyx', 'page', '/about', '--at', 'snap_ancient')
  assert(state['expected:onyx:draft'] == head,
    "a read --at overwrote the branch head with #{state['expected:onyx:draft'].inspect}")
end

check('read of config takes no key') do
  run_cli('read', 'onyx', 'config')
  assert(last_args['read'] == { 'kind' => 'config' }, "got #{last_args['read'].inspect}")
end

check('read --keys posts the batch asset form and answers key => digest') do
  out, _err, code = run_cli('read', 'onyx', 'asset', '--keys', 'assets/a.js,assets/b.css')
  assert(code == 0, "expected exit 0, got #{code}: #{out}")
  assert(last_args['read'] == { 'kind' => 'asset', 'keys' => %w[assets/a.js assets/b.css] },
    "got #{last_args['read'].inspect}")
  assert(JSON.parse(out).dig('data', 'digests').is_a?(Hash), "expected a digests map, got #{out}")
end

check('read --keys with a non-asset kind is refused before any request') do
  before = requests.values.sum
  out, _err, code = run_cli('read', 'onyx', 'page', '--keys', '/about')
  assert(code == 1, 'expected a nonzero exit')
  assert(JSON.parse(out)['code'] == 'USAGE', "expected USAGE, got #{out}")
  assert(requests.values.sum == before, 'a batch read of pages reached the server')
end

check('--json - supplies the whole arguments object from stdin') do
  run_cli('read', 'onyx', '--json', '-', stdin: JSON.generate(kind: 'layout', key: 'default'))
  assert(last_args['read'] == { 'kind' => 'layout', 'key' => 'default' }, "got #{last_args['read'].inspect}")
end

check('save defaults --expected to the remembered branch head and --idempotency-key to a fresh UUID') do
  Dir.mktmpdir do |dir|
    changes = File.join(dir, 'changes.json')
    File.write(changes, JSON.generate([ { op: 'put', kind: 'page', key: '/', document: { format: 'html', metadata: { title: 'Home' }, body: '<p>hi</p>' } } ]))

    before_head = branch_heads['draft']
    out, _err, code = run_cli('save', 'onyx', '--changes', changes)
    assert(code == 0, "expected exit 0, got #{code}: #{out}")
    assert(last_args['save']['expected'] == before_head, "expected the remembered head to be sent, got #{last_args['save']['expected'].inspect}")
    assert(last_args['save']['branch'] == 'draft', 'expected the default branch to be draft')
    assert(last_args['save']['idempotency_key'].match?(/\A[0-9a-f-]{36}\z/), "expected a UUID, got #{last_args['save']['idempotency_key'].inspect}")
    assert(state['expected:onyx:draft'] == branch_heads['draft'], 'expected the new head to be remembered after save')
  end
end

check('a second save with no --expected uses the head the last save returned') do
  Dir.mktmpdir do |dir|
    changes = File.join(dir, 'changes.json')
    File.write(changes, JSON.generate([ { op: 'put', kind: 'page', key: '/two', document: { format: 'html', metadata: { title: 'Two' }, body: '<p>2</p>' } } ]))
    out, _err, code = run_cli('save', 'onyx', '--changes', changes, '--message', 'second')
    assert(code == 0, "expected exit 0, got #{code}: #{out}")
    assert(last_args['save']['message'] == 'second', 'expected --message to be passed through')
  end
end

check('a 409 branch_changed is never retried, prints the structured body, and exits 1') do
  Dir.mktmpdir do |dir|
    changes = File.join(dir, 'changes.json')
    File.write(changes, JSON.generate([ { op: 'put', kind: 'page', key: '/x', document: { format: 'html', metadata: { title: 'X' }, body: '<p>x</p>' } } ]))

    branch_heads['draft'] = 'snap_somebody_else' # someone else committed after our describe
    before = requests["#{TOKEN_ONYX} save"]
    out, _err, code = run_cli('save', 'onyx', '--changes', changes)
    parsed = JSON.parse(out)

    assert(code == 1, "expected exit 1, got #{code}")
    assert(parsed['status'] == 409, "expected the real HTTP status, got #{parsed['status'].inspect}")
    assert(parsed.dig('body', 'error') == 'branch_changed', "expected the structured kind, got #{parsed['body'].inspect}")
    assert(parsed.dig('body', 'expected') == 'snap_somebody_else', "expected the server's current token in the body")
    assert(requests["#{TOKEN_ONYX} save"] == before + 1, 'expected exactly one save request, no automatic retry')
  end
end

check('the 409 body never becomes the new remembered token -- the same save conflicts again') do
  Dir.mktmpdir do |dir|
    changes = File.join(dir, 'changes.json')
    File.write(changes, JSON.generate([ { op: 'put', kind: 'page', key: '/x', document: { format: 'html', metadata: { title: 'X' }, body: '<p>x</p>' } } ]))
    out, _err, code = run_cli('save', 'onyx', '--changes', changes)
    assert(code == 1, 'a save after a conflict must keep failing until the caller rereads')
    assert(JSON.parse(out)['status'] == 409, 'expected the same conflict again')
  end
end

check('an explicit describe picks the new head up, and the next save then succeeds') do
  run_cli('describe', 'onyx')
  Dir.mktmpdir do |dir|
    changes = File.join(dir, 'changes.json')
    File.write(changes, JSON.generate([ { op: 'put', kind: 'page', key: '/x', document: { format: 'html', metadata: { title: 'X' }, body: '<p>x</p>' } } ]))
    out, _err, code = run_cli('save', 'onyx', '--changes', changes)
    assert(code == 0, "expected success once the cache matches the branch head, got: #{out}")
  end
end

check('save with no --expected and nothing remembered fails locally with no HTTP request') do
  Dir.mktmpdir do |dir|
    changes = File.join(dir, 'changes.json')
    File.write(changes, JSON.generate([]))
    before = requests.values.sum
    out, _err, code = run_cli('save', 'onyx', '--changes', changes, '--branch', 'never-seen')
    assert(code == 1, 'expected a nonzero exit')
    assert(JSON.parse(out)['code'] == 'NO_EXPECTED', "expected NO_EXPECTED, got #{out}")
    assert(requests.values.sum == before, 'a save with no CAS token reached the server')
  end
end

check('create-branch posts create_branch and remembers the new branch head') do
  out, _err, code = run_cli('create-branch', 'onyx', 'seo', '--from', 'live')
  assert(code == 0, "expected exit 0, got #{code}: #{out}")
  assert(last_args['create_branch'] == { 'name' => 'seo', 'from' => 'live' }, "got #{last_args['create_branch'].inspect}")
  assert(state['expected:onyx:seo'] == branch_heads['seo'], 'expected the seo head remembered')
end

check('archive-branch posts archive_branch with just the name') do
  out, _err, code = run_cli('archive-branch', 'onyx', 'seo')
  assert(code == 0, "expected exit 0, got #{code}: #{out}")
  assert(last_args['archive_branch'] == { 'name' => 'seo' }, "got #{last_args['archive_branch'].inspect}")
  assert(JSON.parse(out).dig('data', 'archived') == true, "expected the raw envelope, got #{out}")
end

check('archive-branch with no NAME fails locally with no request') do
  before = requests.values.sum
  out, _err, code = run_cli('archive-branch', 'onyx')
  assert(code == 1, 'expected a nonzero exit')
  assert(JSON.parse(out)['code'] == 'USAGE', "expected USAGE, got #{out}")
  assert(requests.values.sum == before, 'an incomplete archive-branch reached the server')
end

check('diff posts diff with branch and against') do
  run_cli('diff', 'onyx', '--branch', 'seo', '--against', 'draft')
  assert(last_args['diff'] == { 'branch' => 'seo', 'against' => 'draft' }, "got #{last_args['diff'].inspect}")
end

check('publish --review posts the review token with a fresh idempotency key') do
  out, _err, code = run_cli('publish', 'onyx', '--review', 'rev_abc')
  assert(code == 0, "expected exit 0, got #{code}: #{out}")
  assert(last_args['publish']['review'] == 'rev_abc', "got #{last_args['publish'].inspect}")
  assert(last_args['publish']['idempotency_key'].match?(/\A[0-9a-f-]{36}\z/), 'expected a UUID idempotency key')
  assert(JSON.parse(out).dig('data', 'published') == true, 'expected the raw publish envelope')
end

check('publish --keys defaults --expected to the remembered head and never treats published:false as success') do
  out, err, code = run_cli('publish', 'onyx', '--keys', 'page:/about,asset:assets/x.js')
  assert(code == 0, "a 200 {published:false} is still a 200, got #{code}: #{out}")
  assert(last_args['publish']['keys'] == [ 'page:/about', 'asset:assets/x.js' ], "got #{last_args['publish'].inspect}")
  assert(last_args['publish']['expected'] == branch_heads['draft'], 'expected the remembered draft head')
  assert(JSON.parse(out).dig('data', 'published') == false, 'expected published:false to be printed verbatim')
  assert(JSON.parse(out).dig('data', 'review') == 'rev_subset', 'expected the subset review to be printed')
  assert(JSON.parse(out).dig('data', 'preview_url').to_s.include?('gxbsites.com'), 'expected the preview URL printed')
  assert(err.include?('published: false'), "expected a published:false warning on stderr, got #{err.inspect}")
  assert(err.include?('--review'), "expected the next step to name publish --review, got #{err.inspect}")
end

check('the review from a published:false is remembered under last_review, never as an expected token') do
  assert(state['last_review:onyx:draft'] == 'rev_subset', "got #{state['last_review:onyx:draft'].inspect}")
  assert(state['expected:onyx:draft'] == branch_heads['draft'], 'a review overwrote the branch head token')
  assert(state.values.count('rev_subset') == 1, 'the review was cached under more than one key')
end

check('publish --review last spends the remembered review and then forgets it') do
  out, _err, code = run_cli('publish', 'onyx', '--review', 'last')
  assert(code == 0, "expected exit 0, got #{code}: #{out}")
  assert(last_args['publish']['review'] == 'rev_subset', "got #{last_args['publish'].inspect}")
  assert(JSON.parse(out).dig('data', 'published') == true, 'expected published:true')
  assert(state['last_review:onyx:draft'].nil?, 'a spent review stayed in the cache')
end

check('publish --review last with nothing remembered fails locally with no request') do
  before = requests.values.sum
  out, _err, code = run_cli('publish', 'onyx', '--review', 'last')
  assert(code == 1, 'expected a nonzero exit')
  assert(JSON.parse(out)['code'] == 'NO_REVIEW', "expected NO_REVIEW, got #{out}")
  assert(requests.values.sum == before, 'a publish with no review reached the server')
end

check('a save whose build is not ready drops the remembered review rather than leaving a stale one') do
  Dir.mktmpdir do |dir|
    run_cli('describe', 'onyx') # describe offers branches[].review, so one is remembered
    assert(state['last_review:onyx:draft'], 'expected describe to remember a review')

    changes = File.join(dir, 'changes.json')
    File.write(changes, JSON.generate([ { op: 'put', kind: 'page', key: '/later', document: { format: 'html', metadata: { title: 'L' }, body: '<p>l</p>' } } ]))
    out, _err, code = run_cli('save', 'onyx', '--changes', changes)
    assert(code == 0, "expected exit 0, got #{code}: #{out}")
    assert(state['last_review:onyx:draft'].nil?, "an explicit review:null left #{state['last_review:onyx:draft'].inspect} behind")
  end
end

check('publish SLUG PATH still uses the legacy expected_version contract') do
  run_cli('read_file', 'acme', 'about.md')
  run_cli('publish', 'acme', 'about.md')
  assert(last_args['publish'].key?('path'), "expected the legacy path form, got #{last_args['publish'].inspect}")
  assert(last_args['publish']['expected_version'] == 'v1', "got #{last_args['publish'].inspect}")
end

check('merge-live posts branch, expected, expected_live and an idempotency key') do
  out, _err, code = run_cli('merge-live', 'onyx', '--expected-live', '7')
  assert(code == 0, "expected exit 0, got #{code}: #{out}")
  assert(last_args['merge_live']['expected_live'] == '7', "got #{last_args['merge_live'].inspect}")
  assert(last_args['merge_live']['branch'] == 'draft', 'expected the default branch')
  assert(state['expected:onyx:draft'] == branch_heads['draft'], 'expected the merged head remembered')
end

check('resolve-merge posts the proposal token and the resolutions array') do
  Dir.mktmpdir do |dir|
    file = File.join(dir, 'resolutions.json')
    File.write(file, JSON.generate([ { key: 'page:/', take: 'ours' } ]))
    out, _err, code = run_cli('resolve-merge', 'onyx', '--proposal', 'mp_1', '--resolutions', file)
    assert(code == 0, "expected exit 0, got #{code}: #{out}")
    assert(last_args['resolve_merge']['merge_proposal'] == 'mp_1', "got #{last_args['resolve_merge'].inspect}")
    assert(last_args['resolve_merge']['resolutions'] == [ { 'key' => 'page:/', 'take' => 'ours' } ], "got #{last_args['resolve_merge'].inspect}")
  end
end

check('history posts branch and limit') do
  run_cli('history', 'onyx', '--branch', 'seo', '--limit', '5')
  assert(last_args['history'] == { 'branch' => 'seo', 'limit' => 5 }, "got #{last_args['history'].inspect}")
end

check('revoke-preview sends a URL as preview_url and a bare token as token') do
  run_cli('revoke-preview', 'onyx', 'https://abcdefghijklmn-onyx.gxbsites.com')
  assert(last_args['revoke_preview'] == { 'preview_url' => 'https://abcdefghijklmn-onyx.gxbsites.com' },
    "got #{last_args['revoke_preview'].inspect}")
  run_cli('revoke-preview', 'onyx', 'abcdefghijklmn')
  assert(last_args['revoke_preview'] == { 'token' => 'abcdefghijklmn' }, "got #{last_args['revoke_preview'].inspect}")
end

check('wait-preview polls describe_site until the branch preview is ready') do
  preview_queue.replace(%w[queued building ready])
  before = requests["#{TOKEN_ONYX} describe_site"]
  out, _err, code = run_cli('wait-preview', 'onyx', '--timeout', '30')
  assert(code == 0, "expected exit 0 on a ready preview, got #{code}: #{out}")
  assert(JSON.parse(out).dig('data', 'preview_status') == 'ready', "got #{out}")
  assert(requests["#{TOKEN_ONYX} describe_site"] == before + 3, 'expected three polls, one per queued status')
end

check('wait-preview exits nonzero on an invalid preview and prints the diagnostics payload') do
  preview_queue.replace(%w[building invalid])
  out, _err, code = run_cli('wait-preview', 'onyx', '--timeout', '30')
  assert(code == 1, "expected exit 1 on an invalid preview, got #{code}: #{out}")
  parsed = JSON.parse(out)
  assert(parsed['code'] == 'INVALID', "expected code INVALID, got #{parsed['code'].inspect}")
  assert(parsed.dig('body', 'preview_status') == 'invalid', "expected the final payload in the body, got #{out}")
end

check('wait-preview treats provisioning as terminal success and says why the URL will not open') do
  preview_queue.replace(%w[queued provisioning])
  before = requests["#{TOKEN_ONYX} describe_site"]
  out, _err, code = run_cli('wait-preview', 'onyx', '--timeout', '30')
  assert(code == 0, "expected exit 0 on provisioning, got #{code}: #{out}")
  parsed = JSON.parse(out)
  assert(parsed.dig('data', 'preview_status') == 'provisioning', "got #{out}")
  assert(parsed.dig('data', 'message').to_s.include?('wildcard certificate'),
    "expected the message to name the wildcard certificate, got #{parsed.dig('data', 'message').inspect}")
  assert(requests["#{TOKEN_ONYX} describe_site"] == before + 2, 'provisioning must stop the poll, not spin the timeout')
end

check('wait-preview treats revoked as terminal failure') do
  preview_queue.replace(%w[revoked])
  out, _err, code = run_cli('wait-preview', 'onyx', '--timeout', '30')
  assert(code == 1, "expected exit 1 on a revoked preview, got #{code}: #{out}")
  parsed = JSON.parse(out)
  assert(parsed['code'] == 'REVOKED', "expected code REVOKED, got #{parsed['code'].inspect}")
  assert(parsed['error'].include?('save again'), "expected the recovery named, got #{parsed['error'].inspect}")
end

check('wait-preview treats unavailable as terminal failure') do
  preview_queue.replace(%w[unavailable])
  out, _err, code = run_cli('wait-preview', 'onyx', '--timeout', '30')
  assert(code == 1, "expected exit 1 on an unavailable preview, got #{code}: #{out}")
  assert(JSON.parse(out)['code'] == 'UNAVAILABLE', "expected code UNAVAILABLE, got #{out}")
end

check('wait-preview treats a missing preview_status as an error, not something to wait out') do
  preview_queue.replace([ nil ])
  out, _err, code = run_cli('wait-preview', 'onyx', '--timeout', '30')
  assert(code == 1, "expected exit 1 when the key is absent, got #{code}: #{out}")
  assert(JSON.parse(out)['code'] == 'PREVIEW_MISSING', "expected PREVIEW_MISSING, got #{out}")
end

# -- the platform door (slice F section 4) -----------------------------------

check('list-sites SLUG asks that one site through its own token at the site door') do
  before = requests["#{TOKEN_ONYX} list_sites"]
  out, _err, code = run_cli('list-sites', 'onyx')
  assert(code == 0, "expected exit 0, got #{code}: #{out}")
  assert(requests["#{TOKEN_ONYX} list_sites"] == before + 1, 'expected list_sites to reach the site endpoint')
  assert(requests["#{TOKEN_ONYX} platform:list_sites"] == 0, 'a site token reached the platform endpoint')
end

check('list-sites with no slug and no personal token refuses locally and names both ways out') do
  before = requests.values.sum
  out, _err, code = run_cli('list-sites')
  assert(code == 1, 'expected a nonzero exit')
  parsed = JSON.parse(out)
  assert(parsed['code'] == 'NO_TOKEN', "expected NO_TOKEN, got #{out}")
  assert(parsed['error'].include?('/profile'), 'expected the place a personal token is minted')
  assert(parsed['error'].include?('list-sites SLUG'), 'expected the site-token form to be named')
  assert(requests.values.sum == before, 'list-sites reached the server with no bearer')
end

check('list-sites posts list_sites to /api/v1/platform/tools with a personal bearer') do
  before = requests["#{TOKEN_USER} platform:list_sites"]
  out, _err, code = run_cli('list-sites', env: { 'SITES_CLI_TOKEN' => TOKEN_USER })
  assert(code == 0, "expected exit 0, got #{code}: #{out}")
  assert(requests["#{TOKEN_USER} platform:list_sites"] == before + 1, 'expected the platform endpoint to be used')
  slugs = JSON.parse(out).dig('data', 'sites').map { |s| s['slug'] }
  assert(slugs == %w[onyx acme], "expected every readable site, got #{slugs.inspect}")
end

check('the personal bearer can also come from the _platform entry in tokens.json') do
  tokens = JSON.parse(File.read(TOKENS_PATH))
  begin
    File.write(TOKENS_PATH, JSON.generate(tokens.merge('_platform' => TOKEN_USER)))
    before = requests["#{TOKEN_USER} platform:list_sites"]
    _out, _err, code = run_cli('list-sites')
    assert(code == 0, 'expected the _platform entry to be used as the bearer')
    assert(requests["#{TOKEN_USER} platform:list_sites"] == before + 1, 'expected the platform endpoint to be used')
  ensure
    File.write(TOKENS_PATH, JSON.generate(tokens))
  end
end

check('create-site posts create_site to the platform door and remembers the new draft head') do
  out, _err, code = run_cli('create-site', 'newsite', '--name', 'New Site', env: { 'SITES_CLI_TOKEN' => TOKEN_USER })
  assert(code == 0, "expected exit 0, got #{code}: #{out}")
  assert(requests["#{TOKEN_USER} platform:create_site"] == 1, 'expected create_site at the platform endpoint')
  assert(last_args['platform:create_site'] == { 'slug' => 'newsite', 'name' => 'New Site' },
    "got #{last_args['platform:create_site'].inspect}")
  assert(JSON.parse(out).dig('data', 'expected') == 'snap_newsite0', "expected the new branch token printed, got #{out}")
  assert(state['expected:newsite:draft'] == 'snap_newsite0', 'expected the new site\'s draft head remembered')
end

check('a site token at the platform door is a 403 the CLI prints verbatim') do
  out, _err, code = run_cli('create-site', 'other', '--name', 'Other', env: { 'SITES_CLI_TOKEN' => TOKEN_ONYX })
  assert(code == 1, 'expected a nonzero exit on 403')
  parsed = JSON.parse(out)
  assert(parsed['status'] == 403, "expected the real 403, got #{parsed['status'].inspect}")
  assert(parsed.dig('body', 'error') == 'capability_denied', "expected the structured body, got #{out}")
  assert(parsed.dig('body', 'message').include?('personal token'), "expected the server's own message, got #{out}")
end

check('platform-tools reads the two schemas from the server, not from this file') do
  out, _err, code = run_cli('platform-tools', env: { 'SITES_CLI_TOKEN' => TOKEN_USER })
  assert(code == 0, "expected exit 0, got #{code}: #{out}")
  names = JSON.parse(out).dig('data', 'tools').map { |t| t['name'] }
  assert(names.sort == %w[create_site list_sites], "got #{names.inspect}")
  assert(requests["#{TOKEN_USER} platform:index"] == 1, 'expected a GET at the platform endpoint')
end

check('create-site with no personal bearer refuses locally and names the runner command') do
  before = requests.values.sum
  out, _err, code = run_cli('create-site', 'newsite', '--name', 'New Site')
  assert(code == 1, 'expected a nonzero exit')
  parsed = JSON.parse(out)
  assert(parsed['code'] == 'NO_TOKEN', "expected NO_TOKEN, got #{out}")
  assert(parsed['error'].include?('sites-cli create newsite'), 'expected the runner fallback to be named')
  assert(parsed['error'].include?('/profile'), 'expected the place a personal token is minted')
  assert(requests.values.sum == before, 'create-site reached the server with no bearer')
end

# -- one credential for every door (the personal-door change) -----------------
#
# A slug with no site token of its own falls back to the personal token, and
# then every request names the site. A slug that does have one is sent exactly
# as it always was.

PERSONAL_ENV = { 'SITES_CLI_TOKEN' => TOKEN_USER }.freeze

check('a slug with no site token falls back to the personal token and names the site') do
  before = requests["#{TOKEN_USER} describe_site"]
  out, _err, code = run_cli('describe', 'ghost', env: PERSONAL_ENV)
  assert(code == 0, "expected exit 0, got #{code}: #{out}")
  assert(requests["#{TOKEN_USER} describe_site"] == before + 1, 'expected the personal bearer at the site door')
  assert(last_envelope['describe_site']['site'] == 'ghost',
    "expected the slug in the envelope, got #{last_envelope['describe_site'].inspect}")
end

check('a site token still sends no site field -- its site is the token') do
  run_cli('describe', 'onyx')
  assert(!last_envelope['describe_site'].key?('site'),
    "a site-token request carried #{last_envelope['describe_site'].inspect}")
end

check('a slug with neither credential keeps NO_TOKEN and names both ways out') do
  before = requests.values.sum
  out, _err, code = run_cli('describe', 'ghost')
  assert(code == 1, 'expected a nonzero exit')
  parsed = JSON.parse(out)
  assert(parsed['code'] == 'NO_TOKEN', "expected NO_TOKEN, got #{out}")
  assert(parsed['error'].include?(TOKENS_PATH), 'expected the site-token file to be named')
  assert(parsed['error'].include?('/profile'), 'expected the place a personal token is minted')
  assert(parsed['error'].include?('_platform'), 'expected the personal-token entry to be named')
  assert(requests.values.sum == before, 'a slug with no credential reached the server')
end

# The gap this closes: create-site used to hand back a draft head that nothing
# could then write to without a trip to an admin page to mint a site token.
check('create-site then save works with one credential and no token step in between') do
  out, _err, code = run_cli('create-site', 'flowsite', '--name', 'Flow Site', env: PERSONAL_ENV)
  assert(code == 0, "expected exit 0 on create-site, got #{code}: #{out}")
  assert(state['expected:flowsite:draft'] == 'snap_newsite0', 'expected the new draft head remembered')

  changes = [ { 'op' => 'put', 'kind' => 'page', 'key' => '/',
                'document' => { 'format' => 'html', 'metadata' => { 'title' => 'Flow' }, 'body' => '<p>hi</p>' } } ]
  out, _err, code = run_cli('save', 'flowsite', '--changes', '-', env: PERSONAL_ENV, stdin: JSON.generate(changes))
  assert(code == 0, "expected the save right after create-site to succeed, got #{code}: #{out}")
  assert(last_envelope['save']['site'] == 'flowsite', "expected the site named, got #{last_envelope['save'].inspect}")
  assert(last_args['save']['expected'] == 'snap_newsite0', 'expected the create-site head to be the CAS token')
  assert(JSON.parse(out).dig('data', 'snapshot_created') == true, "expected a snapshot, got #{out}")
end

check('push over a personal token names the site on the read, the uploads and the save') do
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'app.js'), "export const flow = #{SecureRandom.hex(4).inspect};")
    media_sites.clear
    out, err, code = run_cli('push', 'flowsite', dir, env: PERSONAL_ENV)
    assert(code == 0, "expected exit 0, got #{code}: #{out}#{err}")
    assert(last_envelope['read']['site'] == 'flowsite', 'expected the batch asset read to name the site')
    assert(last_envelope['save']['site'] == 'flowsite', 'expected the save to name the site')
    assert(media_sites.any?, 'no media request named a site')
    assert(media_sites.uniq == [ 'flowsite' ], "expected every media request to name flowsite, got #{media_sites.uniq.inspect}")
  end
end

check('upload over a personal token names the site on authorize, complete and the status poll') do
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'solo.css')
    File.write(path, 'body { color: red }')
    media_sites.clear
    out, _err, code = run_cli('upload', 'flowsite', path, env: PERSONAL_ENV)
    assert(code == 0, "expected exit 0, got #{code}: #{out}")
    assert(media_sites.uniq == [ 'flowsite' ], "expected every media request to name flowsite, got #{media_sites.inspect}")
  end
end

# The stub answers a site-less personal request with the server's own 403, so
# a subcommand that forgot the field fails here rather than in production.
check('every tools subcommand names the site when the credential is personal') do
  [ %w[describe ghost], %w[diff ghost], %w[history ghost], %w[analytics ghost],
    %w[list-submissions ghost], %w[read ghost config] ].each do |args|
    last_envelope.clear
    out, = run_cli(*args, env: PERSONAL_ENV)
    sent = last_envelope.values.last
    assert(sent, "#{args.first} sent no request at all: #{out}")
    assert(sent['site'] == 'ghost', "#{args.first} sent #{sent.inspect}")
  end
end

# -- list_submissions and get_analytics ---------------------------------------

check('list-submissions posts form_slug, since and an integer limit') do
  out, _err, code = run_cli('list-submissions', 'onyx', '--form', 'customer',
                            '--since', '2026-09-01T00:00:00Z', '--limit', '5')
  assert(code == 0, "expected exit 0, got #{code}: #{out}")
  assert(last_args['list_submissions'] == { 'form_slug' => 'customer', 'since' => '2026-09-01T00:00:00Z', 'limit' => 5 },
    "got #{last_args['list_submissions'].inspect}")
  assert(JSON.parse(out).dig('data', 'count') == 1, "expected the raw envelope, got #{out}")
end

check('a token without read_submissions gets the 403 verbatim plus how to fix it') do
  out, err, code = run_cli('list-submissions', 'acme')
  assert(code == 1, 'expected a nonzero exit on 403')
  parsed = JSON.parse(out)
  assert(parsed['status'] == 403, "expected the real 403, got #{parsed['status'].inspect}")
  assert(parsed.dig('body', 'capability') == 'read_submissions', "expected the structured body, got #{out}")
  assert(err.include?('read_submissions'), "expected the recovery on stderr, got #{err.inspect}")
  assert(err.include?('mint a token'), "expected the recovery to name minting, got #{err.inspect}")
  assert(err.include?('/profile'), 'expected the personal token to be named as a way out too')
end

check('analytics posts get_analytics with the period') do
  out, _err, code = run_cli('analytics', 'onyx', '--period', '30d')
  assert(code == 0, "expected exit 0, got #{code}: #{out}")
  assert(last_args['get_analytics'] == { 'period' => '30d' }, "got #{last_args['get_analytics'].inspect}")
  assert(JSON.parse(out).dig('data', 'period') == '30d', "expected the raw envelope, got #{out}")
end

check('analytics with no --period sends none and lets the server default') do
  run_cli('analytics', 'onyx')
  assert(last_args['get_analytics'] == {}, "got #{last_args['get_analytics'].inspect}")
end

check('an out-of-range --period is refused before any request') do
  before = requests.values.sum
  out, _err, code = run_cli('analytics', 'onyx', '--period', '90d')
  assert(code == 1, 'expected a nonzero exit')
  assert(JSON.parse(out)['code'] == 'USAGE', "expected USAGE, got #{out}")
  assert(requests.values.sum == before, 'a bad period reached the server')
end

check('an unknown flag is refused before any request is made') do
  before = requests.values.sum
  out, _err, code = run_cli('diff', 'onyx', '--bogus', 'x')
  assert(code == 1, 'expected a nonzero exit')
  assert(JSON.parse(out)['code'] == 'USAGE', "expected USAGE, got #{out}")
  assert(requests.values.sum == before, 'a typo reached the server')
end

# -- upload -------------------------------------------------------------------

UPLOAD_TYPES = {
  'app.js' => 'text/javascript', 'mod.mjs' => 'text/javascript', 'site.css' => 'text/css',
  'logo.svg' => 'image/svg+xml', 'model.glb' => 'model/gltf-binary', 'body.woff' => 'font/woff',
  'body.woff2' => 'font/woff2', 'data.json' => 'application/json', 'LICENSE.txt' => 'text/plain',
  'LICENSE' => 'text/plain', # extensionless, so a vendored notice can ship with its bundle
  'hero.png' => 'image/png', 'hero.jpg' => 'image/jpeg', 'hero.webp' => 'image/webp',
  'spin.gif' => 'image/gif'
}.freeze

check('upload sends one label-less authorize per file with the right content type and digest') do
  Dir.mktmpdir do |dir|
    paths = UPLOAD_TYPES.keys.map do |name|
      path = File.join(dir, name)
      File.write(path, "bytes for #{name}")
      path
    end

    authorized.clear
    out, _err, code = run_cli('upload', 'onyx', *paths)
    assert(code == 0, "expected exit 0, got #{code}: #{out}")

    lines = out.lines.map { |l| JSON.parse(l) }
    assert(lines.size == paths.size, "expected one JSON line per file, got #{lines.size}")
    lines.each do |line|
      name = File.basename(line['path'])
      assert(line['status'] == 'ready', "#{name} was not ready: #{line.inspect}")
      assert(line['media_type'] == UPLOAD_TYPES[name], "#{name} got media_type #{line['media_type'].inspect}")
      assert(line['digest'] == Digest::SHA256.hexdigest("bytes for #{name}"), "#{name} digest mismatch")
      assert(line['url'].to_s.include?(line['digest']), "#{name} url is not the content hash")
      assert(line['byte_size'] == "bytes for #{name}".bytesize, "#{name} byte_size mismatch")
    end

    authorized.each_value do |payload|
      assert(!payload.key?('label'), "a versioned upload sent a label: #{payload.inspect}")
      assert(!payload.key?('expected_version'), "a versioned upload sent expected_version: #{payload.inspect}")
      assert(payload['filename'], "a versioned upload sent no filename: #{payload.inspect}")
      assert(payload['digest'], "a versioned upload sent no digest hint: #{payload.inspect}")
    end
  end
end

check('upload runs four files at a time, never unbounded') do
  Dir.mktmpdir do |dir|
    paths = (1..8).map do |n|
      path = File.join(dir, "p#{n}.js")
      File.write(path, "console.log(#{n})")
      path
    end
    max_concurrent_puts = 0
    out, _err, code = run_cli('upload', 'onyx', *paths)
    assert(code == 0, "expected exit 0, got #{code}: #{out}")
    assert(max_concurrent_puts > 1, "expected real parallelism, saw max #{max_concurrent_puts}")
    assert(max_concurrent_puts <= 4, "expected at most 4 in flight, saw #{max_concurrent_puts}")
  end
end

check('upload exits 1 when one file fails and still reports every file') do
  Dir.mktmpdir do |dir|
    good = File.join(dir, 'good.js')
    bad = File.join(dir, 'bad.js')
    File.write(good, 'ok')
    File.write(bad, 'nope')
    fail_upload_named = 'bad.js'

    out, _err, code = run_cli('upload', 'onyx', good, bad)
    assert(code == 1, "expected exit 1 when a file fails, got #{code}: #{out}")
    lines = out.lines.map { |l| JSON.parse(l) }
    assert(lines.size == 2, "expected two report lines, got #{lines.size}")
    assert(lines.any? { |l| l['status'] == 'failed' && l['path'].end_with?('bad.js') }, "got #{out}")
  end
ensure
  fail_upload_named = nil
end

check('upload types anything the table does not name and sends it anyway') do
  Dir.mktmpdir do |dir|
    notes = File.join(dir, 'notes.md')
    binary = File.join(dir, 'firmware.bin')
    File.write(notes, "# hi #{SecureRandom.hex(4)}")
    File.write(binary, SecureRandom.hex(8))
    authorize_bodies.clear

    out, _err, code = run_cli('upload', 'onyx', notes, binary)
    assert(code == 0, "expected exit 0 now that any type is accepted, got #{code}: #{out}")
    types = authorize_bodies.to_h { |p| [ p['filename'], p['content_type'] ] }
    assert(types['notes.md'] == 'text/markdown', "expected a mime lookup for .md, got #{types.inspect}")
    assert(types['firmware.bin'] == 'application/octet-stream', "expected the octet-stream fallback, got #{types.inspect}")
  end
end

check('an HTML file is sent and the server refusal is printed verbatim, not guessed at locally') do
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'index.html')
    File.write(path, '<!doctype html><title>no</title>')
    out, _err, code = run_cli('upload', 'onyx', path)
    assert(code == 1, "expected exit 1, got #{code}: #{out}")
    line = JSON.parse(out.lines.first)
    assert(line['status'] == 'failed', "got #{line.inspect}")
    assert(line.dig('body', 'error') == 'unsupported_content_type', "expected the server's own body, got #{line.inspect}")
    assert(line['error'].include?('page document'), "expected the server's own message, got #{line.inspect}")
  end
end

check('a file the server asks to send in parts takes the multipart transport whatever its type is') do
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'firmware.iso')
    original = SecureRandom.random_bytes(BIG_PART_SIZE * BIG_PARTS_COUNT)
    File.binwrite(path, original)
    multipart_named = 'firmware.iso'
    big_parts.clear

    out, _err, code = run_cli('upload', 'onyx', path)
    assert(code == 0, "expected exit 0, got #{code}: #{out}")
    reassembled = (1..BIG_PARTS_COUNT).map { |n| big_parts.fetch(n) }.join
    assert(reassembled == original, 'reassembled part bytes did not match the source file')
    assert(JSON.parse(out)['status'] == 'ready', "got #{out}")
  end
ensure
  multipart_named = nil
end

# -- push ---------------------------------------------------------------------

def onyx_tree(dir)
  File.write(File.join(dir, 'app.js'), 'export const a = 1')
  File.write(File.join(dir, 'copy.js'), 'export const a = 1') # identical bytes on purpose
  Dir.mkdir(File.join(dir, 'vendor'))
  File.write(File.join(dir, 'vendor', 'three.module.js'), 'export class Scene {}')
  File.write(File.join(dir, '.hidden.js'), 'secret')
  Dir.mkdir(File.join(dir, '.git'))
  File.write(File.join(dir, '.git', 'config'), 'nope')
end

check('push --offline prints the change list with local digests and makes no request at all') do
  Dir.mktmpdir do |dir|
    onyx_tree(dir)
    before = requests.values.sum
    out, _err, code = run_cli('push', 'onyx', dir, '--offline')
    assert(code == 0, "expected exit 0, got #{code}: #{out}")

    data = JSON.parse(out)['data']
    keys = data['changes'].map { |c| c['key'] }
    assert(keys == %w[assets/app.js assets/copy.js assets/vendor/three.module.js], "got #{keys.inspect}")
    assert(data['changes'].all? { |c| c['op'] == 'put' && c['kind'] == 'asset' }, "got #{data['changes'].inspect}")
    assert(data['changes'][0]['digest'] == Digest::SHA256.hexdigest('export const a = 1'), 'digest is not the local sha256')
    assert(data['contract'] == 'unchecked', "expected --offline to say it checked nothing, got #{data['contract'].inspect}")
    assert(requests.values.sum == before, '--offline reached the server')
  end
end

check('a change object carries only what save takes; media_type rides alongside it') do
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'poster.png'), 'not really a png')
    out, _err, = run_cli('push', 'onyx', dir, '--offline')
    data = JSON.parse(out)['data']
    assert(data['changes'][0].keys.sort == %w[digest key kind op], "got #{data['changes'][0].keys.inspect}")
    detail = data['file_details'][0]
    assert(detail['media_type'] == 'image/png', "expected the declared media type reported, got #{detail.inspect}")
    assert(detail['byte_size'] == 'not really a png'.bytesize, "got #{detail.inspect}")
  end
end

check('push --dry-run asks describe_site which contract the site is on, and nothing else') do
  Dir.mktmpdir do |dir|
    onyx_tree(dir)
    before_describe = requests["#{TOKEN_ONYX} describe_site"]
    before_save = requests["#{TOKEN_ONYX} save"]
    before_authorize = requests["#{TOKEN_ONYX} media_authorize"]

    out, _err, code = run_cli('push', 'onyx', dir, '--dry-run')
    assert(code == 0, "expected exit 0, got #{code}: #{out}")

    data = JSON.parse(out)['data']
    assert(data['contract'] == 'versioned', "got #{data['contract'].inspect}")
    assert(data['expected'] == branch_heads['draft'], "expected the real branch head, got #{data['expected'].inspect}")
    assert(requests["#{TOKEN_ONYX} describe_site"] == before_describe + 1, 'expected exactly one describe_site')
    assert(requests["#{TOKEN_ONYX} save"] == before_save, 'a dry run saved')
    assert(requests["#{TOKEN_ONYX} media_authorize"] == before_authorize, 'a dry run uploaded')
  end
end

check('push --dry-run on a legacy site fails early and names the tool that does work there') do
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'hero.jpg'), 'bytes')
    out, _err, code = run_cli('push', 'acme', dir, '--dry-run')
    assert(code == 1, "expected the rehearsal to refuse a legacy site, got #{code}: #{out}")
    parsed = JSON.parse(out)
    assert(parsed['code'] == 'NOT_VERSIONED', "expected NOT_VERSIONED, got #{out}")
    assert(parsed['error'].include?('write_file'), 'expected the legacy tool to be named')
  end
end

check('push --dry-run on a branch the site does not have fails and names create-branch') do
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'x.js'), 'x')
    out, _err, code = run_cli('push', 'onyx', dir, '--branch', 'never-made', '--dry-run')
    assert(code == 1, "expected a nonzero exit, got #{code}: #{out}")
    parsed = JSON.parse(out)
    assert(parsed['code'] == 'NO_BRANCH', "expected NO_BRANCH, got #{out}")
    assert(parsed['error'].include?('create-branch'), 'expected create-branch to be named')
  end
end

check('push skips dotfiles and dot directories') do
  Dir.mktmpdir do |dir|
    onyx_tree(dir)
    out, _err, = run_cli('push', 'onyx', dir, '--offline')
    keys = JSON.parse(out)['data']['changes'].map { |c| c['key'] }
    assert(keys.none? { |k| k.include?('.hidden') || k.include?('.git') }, "got #{keys.inspect}")
  end
end

check('push does not prefix a tree that already starts with the prefix') do
  Dir.mktmpdir do |dir|
    Dir.mkdir(File.join(dir, 'assets'))
    File.write(File.join(dir, 'assets', 'x.js'), 'x')
    out, _err, = run_cli('push', 'onyx', dir, '--offline')
    keys = JSON.parse(out)['data']['changes'].map { |c| c['key'] }
    assert(keys == %w[assets/x.js], "got #{keys.inspect}")
  end
end

check('push accepts an extensionless LICENSE as text/plain, so a vendored notice can ship') do
  Dir.mktmpdir do |dir|
    Dir.mkdir(File.join(dir, 'vendor'))
    File.write(File.join(dir, 'vendor', 'LICENSE'), 'MIT License')
    File.write(File.join(dir, 'vendor', 'three.module.js'), 'export class Scene {}')
    out, _err, code = run_cli('push', 'onyx', dir, '--offline')
    assert(code == 0, "expected exit 0, got #{code}: #{out}")
    details = JSON.parse(out)['data']['file_details']
    licence = details.find { |d| d['key'].end_with?('LICENSE') }
    assert(licence, "expected the licence in the change list, got #{details.inspect}")
    assert(licence['media_type'] == 'text/plain', "got #{licence.inspect}")
  end
end

check('push types a file the table does not name rather than refusing the whole tree') do
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'notes.md'), '# hi')
    File.write(File.join(dir, 'firmware.bin'), 'binary')
    out, _err, code = run_cli('push', 'onyx', dir, '--offline')
    assert(code == 0, "expected exit 0 now that any type is accepted, got #{code}: #{out}")
    types = JSON.parse(out)['data']['file_details'].to_h { |d| [ File.basename(d['key']), d['media_type'] ] }
    assert(types['notes.md'] == 'text/markdown', "got #{types.inspect}")
    assert(types['firmware.bin'] == 'application/octet-stream', "got #{types.inspect}")
  end
end

check('push says on stderr that an HTML file belongs in a page document') do
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'index.html'), '<!doctype html>')
    _out, err, code = run_cli('push', 'onyx', dir, '--offline')
    assert(code == 0, 'expected the rehearsal to still run')
    assert(err.include?('page document'), "expected the note on stderr, got #{err.inspect}")
    assert(err.include?('save --page'), "expected the tool that does work to be named, got #{err.inspect}")
  end
end

# The blocker: pc_60d7aa4c, pc_e3810da4, pc_c3606ecf. Authorize answers `ready`
# with a blob URL and no upload_url when the platform already holds the bytes.
check('a second upload of the same bytes is the dedup fast path: no PUT, no complete, no crash') do
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'dedup.css')
    File.write(path, "body { color: ##{SecureRandom.hex(3)} }")

    out, _err, code = run_cli('upload', 'onyx', path)
    assert(code == 0, "expected the first upload to succeed, got #{code}: #{out}")
    digest = JSON.parse(out)['digest']

    before_complete = requests["#{TOKEN_ONYX} media_complete"]
    before_puts = uploaded.size
    out, err, code = run_cli('upload', 'onyx', path)
    assert(code == 0, "expected exit 0 on the dedup path, got #{code}: #{out}#{err}")
    assert(!err.include?('Thread'), "a thread backtrace reached stderr: #{err.inspect}")

    line = JSON.parse(out)
    assert(line['status'] == 'ready', "expected a ready line, got #{line.inspect}")
    assert(line['digest'] == digest, "expected the same digest, got #{line.inspect}")
    assert(line['deduplicated'] == true, "expected the line to say the bytes were already there, got #{line.inspect}")
    assert(line['url'].to_s.include?(digest), "expected the blob URL, got #{line.inspect}")
    assert(requests["#{TOKEN_ONYX} media_complete"] == before_complete, 'a deduped upload called complete')
    assert(uploaded.size == before_puts, 'a deduped upload sent bytes')
  end
end

check('push over a tree the platform already holds saves the keys and sends no bytes') do
  Dir.mktmpdir do |dir|
    body = "const shared = #{SecureRandom.hex(4).inspect}"
    File.write(File.join(dir, 'shared.js'), body)
    run_cli('upload', 'onyx', File.join(dir, 'shared.js')) # the platform now holds these bytes

    run_cli('describe', 'onyx')
    before_puts = uploaded.size
    out, err, code = run_cli('push', 'onyx', dir)
    assert(code == 0, "expected exit 0, got #{code}: #{out}#{err}")
    assert(uploaded.size == before_puts, 'push sent bytes the platform already had')
    assert(err.include?('already on the platform'), "expected the dedup note on stderr, got #{err.inspect}")
    assert(last_args['save']['changes'].map { |c| c['key'] } == %w[assets/shared.js], "got #{last_args['save'].inspect}")
  end
end

check('an authorize shape nothing expects becomes a structured error with the body, never a backtrace') do
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'odd.js')
    File.write(path, "const odd = #{SecureRandom.hex(4).inspect}")
    weird_authorize = true

    out, err, code = run_cli('upload', 'onyx', path)
    assert(code == 1, "expected exit 1, got #{code}: #{out}")
    assert(!err.include?('backtrace') && !err.include?('.rb:'), "expected no Ruby trace, got #{err.inspect}")
    line = JSON.parse(out)
    assert(line['code'] == 'UPLOAD_UNEXPECTED', "expected UPLOAD_UNEXPECTED, got #{line.inspect}")
    assert(line.dig('body', 'status') == 'contemplating', "expected the server's body attached, got #{line.inspect}")
  end
ensure
  weird_authorize = nil
end

check('push --dry-run on a tree with no assets exits 0 and still checks the contract') do
  Dir.mktmpdir do |dir|
    before_describe = requests["#{TOKEN_ONYX} describe_site"]
    out, _err, code = run_cli('push', 'onyx', dir, '--dry-run')
    assert(code == 0, "expected exit 0 on an empty tree, got #{code}: #{out}")
    data = JSON.parse(out)['data']
    assert(data['files'] == 0 && data['saved'] == false && data['changes'] == [], "got #{data.inspect}")
    assert(data['contract'] == 'versioned', "expected the contract checked, got #{data.inspect}")
    assert(requests["#{TOKEN_ONYX} describe_site"] == before_describe + 1, 'expected exactly one describe_site')
  end
end

check('push on a tree with no assets exits 0 too, so push && save needs no special case') do
  Dir.mktmpdir do |dir|
    before_save = requests["#{TOKEN_ONYX} save"]
    out, _err, code = run_cli('push', 'onyx', dir)
    assert(code == 0, "expected exit 0, got #{code}: #{out}")
    assert(JSON.parse(out).dig('data', 'saved') == false, "got #{out}")
    assert(requests["#{TOKEN_ONYX} save"] == before_save, 'an empty tree emitted a save')
  end
end

check('push uploads each distinct digest once and emits exactly one save with every key') do
  Dir.mktmpdir do |dir|
    onyx_tree(dir)
    run_cli('describe', 'onyx') # refresh the remembered head
    before_authorize = requests["#{TOKEN_ONYX} media_authorize"]
    before_save = requests["#{TOKEN_ONYX} save"]
    head = branch_heads['draft']

    out, _err, code = run_cli('push', 'onyx', dir)
    assert(code == 0, "expected exit 0, got #{code}: #{out}")

    uploads = requests["#{TOKEN_ONYX} media_authorize"] - before_authorize
    assert(uploads == 2, "expected two uploads for three files with two distinct digests, got #{uploads}")
    assert(requests["#{TOKEN_ONYX} save"] == before_save + 1, 'expected exactly one save')

    keys = last_args['save']['changes'].map { |c| c['key'] }
    assert(keys == %w[assets/app.js assets/copy.js assets/vendor/three.module.js], "got #{keys.inspect}")
    assert(last_args['save']['expected'] == head, 'expected push to use the remembered branch head')
    assert(JSON.parse(out).dig('data', 'snapshot_created') == true, 'expected the save response to be printed')
  end
end

check('push skips files already bound at the same digest and saves only what changed') do
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'one.js'), 'const one = 1')
    File.write(File.join(dir, 'two.js'), 'const two = 2')
    run_cli('describe', 'onyx')

    out, _err, code = run_cli('push', 'onyx', dir)
    assert(code == 0, "expected the first push to succeed, got: #{out}")
    assert(last_args['save']['changes'].size == 2, "got #{last_args['save']['changes'].inspect}")
    assert(last_args['read'] == { 'kind' => 'asset', 'keys' => %w[assets/one.js assets/two.js], 'branch' => 'draft' },
      "expected push to ask the batch read first, got #{last_args['read'].inspect}")

    before_authorize = requests["#{TOKEN_ONYX} media_authorize"]
    before_save = requests["#{TOKEN_ONYX} save"]
    out, err, code = run_cli('push', 'onyx', dir)
    assert(code == 0, "expected exit 0 on an unchanged tree, got #{code}: #{out}")
    assert(requests["#{TOKEN_ONYX} media_authorize"] == before_authorize, 'an unchanged file was uploaded again')
    assert(requests["#{TOKEN_ONYX} save"] == before_save, 'an unchanged tree still emitted a save')
    assert(JSON.parse(out).dig('data', 'saved') == false, "got #{out}")
    assert(JSON.parse(out).dig('data', 'unchanged') == 2, "got #{out}")
    assert(err.include?('already bound'), "expected a skip note on stderr, got #{err.inspect}")

    File.write(File.join(dir, 'two.js'), 'const two = 22')
    out, _err, code = run_cli('push', 'onyx', dir)
    assert(code == 0, "expected exit 0, got #{code}: #{out}")
    assert(requests["#{TOKEN_ONYX} media_authorize"] == before_authorize + 1, 'expected exactly one upload for one changed file')
    keys = last_args['save']['changes'].map { |c| c['key'] }
    assert(keys == %w[assets/two.js], "got #{keys.inspect}")
  end
end

check('push falls back to uploading everything when the server has no batch asset read') do
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'solo.js'), 'const solo = 1')
    run_cli('describe', 'onyx')
    fail_batch_read = true
    before_authorize = requests["#{TOKEN_ONYX} media_authorize"]

    out, _err, code = run_cli('push', 'onyx', dir)
    assert(code == 0, "expected the push to survive a server with no batch read, got #{code}: #{out}")
    assert(requests["#{TOKEN_ONYX} media_authorize"] == before_authorize + 1, 'expected the file to be uploaded anyway')
    assert(last_args['save']['changes'].map { |c| c['key'] } == %w[assets/solo.js], "got #{last_args['save'].inspect}")
  end
ensure
  fail_batch_read = false
end

check('push says so when the platform types a file differently from its name') do
  Dir.mktmpdir do |dir|
    # JPEG magic under a .png name, exactly like Onyx's poster (friction 15)
    File.binwrite(File.join(dir, 'poster.png'), "\xFF\xD8\xFF\xE0jpeg bytes".b)
    run_cli('describe', 'onyx')
    _out, err, code = run_cli('push', 'onyx', dir)
    assert(code == 0, "expected exit 0, got #{code}")
    assert(err.include?('poster.png is image/jpeg'), "expected the real media type on stderr, got #{err.inspect}")
  end
end

check('push uploads nothing to save when an upload fails') do
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, 'app.js'), 'a')
    File.write(File.join(dir, 'broken.js'), 'b')
    run_cli('describe', 'onyx')
    fail_upload_named = 'broken.js'
    before_save = requests["#{TOKEN_ONYX} save"]

    out, _err, code = run_cli('push', 'onyx', dir)
    assert(code == 1, "expected exit 1, got #{code}: #{out}")
    assert(requests["#{TOKEN_ONYX} save"] == before_save, 'a failed upload still reached save')
  end
ensure
  fail_upload_named = nil
end

# -- check (agent-browser wrapper) --------------------------------------------

BROWSER_LOG = File.join(CONFIG_DIR, 'browser.log')
BROWSER_STUB = File.join(CONFIG_DIR, 'agent-browser-stub')
File.write(BROWSER_STUB, <<~'STUB')
  #!/usr/bin/env ruby
  require 'json'
  args = ARGV.dup
  args.delete('--json')
  session = nil
  if (i = args.index('--session'))
    args.delete_at(i)
    session = args.delete_at(i)
  end
  File.open(ENV.fetch('STUB_BROWSER_LOG'), 'a') { |f| f.puts("#{session} #{args.join(' ')}") }
  mode = ENV['STUB_BROWSER_MODE']
  broken = mode == 'broken'
  url = args[1] || 'http://stub.test/'

  # a preview hostname whose wildcard certificate is not installed yet
  if mode == 'tls' && args[0] == 'open' && args[1]
    puts JSON.generate(success: false, data: nil, error: 'Navigation failed: net::ERR_SSL_PROTOCOL_ERROR')
    exit 0
  end

  out =
    case [args[0], args[1]]
    in ['open', nil] then { title: nil, url: 'about:blank' }
    in ['open', String => u] then { title: 'Stub Page', url: u }
    in ['console', _]
      { messages: broken ? [{ type: 'error', text: 'boom one' }, { type: 'log', text: 'noise' }] : [] }
    in ['errors', _]
      { errors: broken ? [{ text: 'ReferenceError: undefinedFn is not defined' }] : [] }
    in ['network', 'requests']
      requests = [{ url: ENV.fetch('STUB_BROWSER_URL'), status: 200, resourceType: 'Document' }]
      if broken
        requests << { url: "#{ENV.fetch('STUB_BROWSER_URL')}missing.png", status: 404, resourceType: 'Image' }
        requests << { url: "#{ENV.fetch('STUB_BROWSER_URL')}favicon.ico", status: 404, resourceType: 'Other' }
      end
      # what a blocked cross-origin module looks like: no status, no console
      if mode == 'cors'
        requests << { url: ENV.fetch('STUB_BROWSER_CORS_URL'), resourceType: 'Script', errorText: 'net::ERR_FAILED' }
      end
      { requests: requests }
    in ['screenshot', String => path]
      File.write(path, 'PNG')
      { path: path }
    else { }
    end

  puts JSON.generate(success: true, data: out, error: nil)
STUB
File.chmod(0o755, BROWSER_STUB)

BROWSER_ENV = { 'SITES_CLI_BROWSER' => BROWSER_STUB, 'STUB_BROWSER_LOG' => BROWSER_LOG,
                'STUB_BROWSER_URL' => 'http://stub.test/' }.freeze

check('check reports a clean page, exits 0, sets the viewport and always closes the session') do
  File.write(BROWSER_LOG, '')
  out, _err, code = run_cli('check', 'http://stub.test/', '--width', '1280', env: BROWSER_ENV)
  assert(code == 0, "expected exit 0 on a clean page, got #{code}: #{out}")

  parsed = JSON.parse(out)
  assert(parsed['status'] == 200, "got #{parsed['status'].inspect}")
  assert(parsed['title'] == 'Stub Page', "got #{parsed['title'].inspect}")
  assert(parsed['console_errors'] == [], "got #{parsed['console_errors'].inspect}")
  assert(parsed['failed_requests'] == [], "got #{parsed['failed_requests'].inspect}")

  log = File.read(BROWSER_LOG)
  assert(log.include?('set viewport 1280 900'), "expected the viewport to be set: #{log}")
  assert(log.include?('wait --load networkidle'), "expected a networkidle wait: #{log}")
  assert(log.lines.last.include?('close'), "expected the session to be closed last: #{log}")
  sessions = log.lines.map { |l| l.split(' ').first }.uniq
  assert(sessions.size == 1, "expected one session per run, got #{sessions.inspect}")
end

check('check exits 1 on console errors and failed requests, and reports both') do
  File.write(BROWSER_LOG, '')
  out, _err, code = run_cli('check', 'http://stub.test/', env: BROWSER_ENV.merge('STUB_BROWSER_MODE' => 'broken'))
  assert(code == 1, "expected exit 1, got #{code}: #{out}")

  parsed = JSON.parse(out)
  assert(parsed['console_errors'] == [ 'boom one', 'ReferenceError: undefinedFn is not defined' ],
    "expected console messages and page errors merged, got #{parsed['console_errors'].inspect}")
  urls = parsed['failed_requests'].map { |r| r['url'] }
  assert(urls.sort == [ 'http://stub.test/favicon.ico', 'http://stub.test/missing.png' ], "got #{urls.inspect}")
  assert(File.read(BROWSER_LOG).lines.last.include?('close'), 'expected the session to be closed after a failing check')
end

check('check --ignore drops matching failed requests') do
  out, _err, code = run_cli('check', 'http://stub.test/', '--ignore', 'favicon',
                            env: BROWSER_ENV.merge('STUB_BROWSER_MODE' => 'broken'))
  urls = JSON.parse(out)['failed_requests'].map { |r| r['url'] }
  assert(urls == [ 'http://stub.test/missing.png' ], "got #{urls.inspect}")
  assert(code == 1, 'console errors alone still fail the check')
end

check('check tells a CORS block from a missing object, and says which on stdout and stderr') do
  cors_url = "http://127.0.0.1:#{port}/cors/blocked.js"
  out, err, code = run_cli('check', 'http://stub.test/',
                           env: BROWSER_ENV.merge('STUB_BROWSER_MODE' => 'cors', 'STUB_BROWSER_CORS_URL' => cors_url))
  assert(code == 1, "expected exit 1 on a blocked subresource, got #{code}: #{out}")

  failure = JSON.parse(out)['failed_requests'].find { |r| r['url'] == cors_url }
  assert(failure, "expected the blocked request reported, got #{out}")
  assert(failure['error'] == 'net::ERR_FAILED', "expected the browser's own failure text carried, got #{failure.inspect}")
  assert(failure['diagnosis'] == 'cors_blocked', "expected a CORS diagnosis, got #{failure.inspect}")
  assert(failure.dig('probe', 'status') == 200, "expected the probe to find the object present, got #{failure.inspect}")
  assert(failure['message'].include?('bucket CORS'), "got #{failure['message'].inspect}")
  assert(err.include?('bucket CORS'), "expected the diagnosis in prose on stderr, got #{err.inspect}")
end

check('check --no-probe asks the object nothing') do
  cors_url = "http://127.0.0.1:#{port}/cors/blocked.js"
  before = requests['cors_probe']
  out, _err, code = run_cli('check', 'http://stub.test/', '--no-probe',
                            env: BROWSER_ENV.merge('STUB_BROWSER_MODE' => 'cors', 'STUB_BROWSER_CORS_URL' => cors_url))
  assert(code == 1, "expected exit 1, got #{code}: #{out}")
  assert(requests['cors_probe'] == before, '--no-probe still fetched the object')
  failure = JSON.parse(out)['failed_requests'].find { |r| r['url'] == cors_url }
  assert(failure['diagnosis'].nil?, "expected no diagnosis without a probe, got #{failure.inspect}")
end

check('a same-origin failure with a status is never probed -- the browser already got an answer') do
  before = requests['cors_probe']
  run_cli('check', 'http://stub.test/', env: BROWSER_ENV.merge('STUB_BROWSER_MODE' => 'broken'))
  assert(requests['cors_probe'] == before, 'a 404 with a status was probed anyway')
end

check('check names the missing preview wildcard certificate rather than just the TLS error') do
  out, _err, code = run_cli('check', 'https://orst2izx5hazhn-onyx.gxbsites.com',
                            env: BROWSER_ENV.merge('STUB_BROWSER_MODE' => 'tls'))
  assert(code == 1, "expected a nonzero exit, got #{code}: #{out}")
  parsed = JSON.parse(out)
  assert(parsed['code'] == 'PREVIEW_TLS', "expected PREVIEW_TLS, got #{out}")
  assert(parsed['error'].include?('wildcard certificate'), "expected the real cause named, got #{parsed['error'].inspect}")
  assert(parsed['error'].include?('ERR_SSL_PROTOCOL_ERROR'), 'expected the browser error preserved too')
end

check('a live hostname keeps the plain browser error -- the hint is only for preview hosts') do
  out, _err, code = run_cli('check', 'https://onyx.gxbsites.com', env: BROWSER_ENV.merge('STUB_BROWSER_MODE' => 'tls'))
  assert(code == 1, 'expected a nonzero exit')
  assert(JSON.parse(out)['code'] == 'BROWSER_ERROR', "got #{out}")
end

check('check writes the screenshot it was asked for') do
  Dir.mktmpdir do |dir|
    shot = File.join(dir, 'shots', 'home.png')
    out, _err, code = run_cli('check', 'http://stub.test/', '--screenshot', shot, env: BROWSER_ENV)
    assert(code == 0, "expected exit 0, got #{code}: #{out}")
    assert(File.file?(shot), 'expected the screenshot file to exist')
    assert(JSON.parse(out)['screenshot'] == shot, "expected the screenshot path in the report, got #{out}")
  end
end

# -- fragment: a full HTML document -> a page body ----------------------------

ONYX_PAGE = <<~HTML
  <!doctype html>
  <html lang="en">
  <head>
    <meta charset="utf-8">
    <title>Onyx &mdash; A new way to build the grid.</title>
    <meta name="description" content="Stealth hardware.">
    <meta name="robots" content="noindex">
    <link rel="icon" href="assets/onyx-favicon.svg">
    <link rel="stylesheet" href="assets/stealth.css">
    <link rel="stylesheet" href="https://fonts.example.com/inter.css">
    <script type="importmap">{"imports":{"three":"./assets/vendor/three/three.module.js"}}</script>
    <script type="module" src="assets/onyx-core-motion.js"></script>
    <style>.hero { color: red; }</style>
  </head>
  <body>
    <a class="skip" href="#main">Skip to content</a>
    <main id="main" class="hero">
      <img src="assets/onyx-logo-light.svg" alt="Onyx">
      <div class="motion-stage" data-asset="assets/onyx-motion-studies.glb"></div>
      <form id="inquiry-form" action="/f/customer" method="post"></form>
      <script>document.addEventListener('submit', (e) => { e.preventDefault(); });</script>
    </main>
  </body>
  </html>
HTML

def with_page_file(html = ONYX_PAGE)
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'index.html')
    File.write(path, html)
    yield dir, path
  end
end

check('fragment drops the document shell and carries the head into config and metadata') do
  with_page_file do |_dir, path|
    out, _err, code = run_cli('fragment', path)
    assert(code == 0, "expected exit 0, got #{code}: #{out}")
    data = JSON.parse(out)['data']

    assert(data['metadata']['title'] == 'Onyx — A new way to build the grid.', "got #{data['metadata'].inspect}")
    assert(data['metadata']['description'] == 'Stealth hardware.', "got #{data['metadata'].inspect}")
    assert(data['metadata']['noindex'] == true, "got #{data['metadata'].inspect}")
    assert(data['config']['stylesheets'] == %w[assets/stealth.css], "got #{data['config'].inspect}")
    assert(data['config']['modules'] == %w[assets/onyx-core-motion.js], "got #{data['config'].inspect}")
    assert(data['config']['imports'] == { 'three' => 'assets/vendor/three/three.module.js' }, "got #{data['config'].inspect}")
    assert(data['config']['favicon'] == { 'url' => 'assets/onyx-favicon.svg' }, "got #{data['config'].inspect}")
    assert(data['css'] == '.hero { color: red; }', "got #{data['css'].inspect}")
  end
end

check('fragment rewrites every local assets/ reference to {{ asset: }} and leaves nothing of the shell') do
  with_page_file do |_dir, path|
    body = JSON.parse(run_cli('fragment', path).first).dig('data', 'body')
    assert(body.include?('src="{{ asset:assets/onyx-logo-light.svg }}"'), "got #{body}")
    assert(body.include?('data-asset="{{ asset:assets/onyx-motion-studies.glb }}"'), "got #{body}")
    %w[<!doctype <html <head <title <meta <link <main importmap Skip\ to\ content].each do |gone|
      assert(!body.include?(gone), "#{gone.inspect} survived into the body: #{body}")
    end
    assert(body.start_with?('<div class="hero">'), "expected <main> to become a div, got #{body[0, 60]}")
    assert(body.include?("<script>document.addEventListener"), 'the page\'s own inline script was dropped')
  end
end

check('fragment warns about the things that only break later: forms-1.js, an SVG favicon, an external sheet') do
  with_page_file do |_dir, path|
    _out, err, = run_cli('fragment', path)
    assert(err.include?('stopPropagation'), "expected the double-submit warning, got #{err.inspect}")
    assert(err.include?('415'), "expected the SVG favicon warning, got #{err.inspect}")
    assert(err.include?('fonts.example.com'), "expected the external stylesheet warning, got #{err.inspect}")
  end
end

check('fragment reports its change list on stderr and stdout stays one JSON envelope') do
  with_page_file do |_dir, path|
    out, err, = run_cli('fragment', path)
    assert(out.lines.size == 1, "expected exactly one line on stdout, got #{out.lines.size}")
    assert(JSON.parse(out)['ok'] == true, 'expected the envelope')
    assert(err.include?('fragment: dropped the document shell'), "got #{err.inspect}")
    assert(JSON.parse(out).dig('data', 'changes').size >= 8, 'expected the change list in the payload too')
  end
end

check('fragment leaves a body that is already a fragment alone, except for asset references') do
  with_page_file('<p><img src="assets/x.png"></p>') do |_dir, path|
    data = JSON.parse(run_cli('fragment', path).first)['data']
    assert(data['body'] == '<p><img src="{{ asset:assets/x.png }}"></p>', "got #{data['body'].inspect}")
    assert(data['metadata'] == {}, "got #{data['metadata'].inspect}")
    assert(!data['changes'].any? { |c| c.include?('document shell') }, "got #{data['changes'].inspect}")
  end
end

# -- save --page --html --config ----------------------------------------------

check('save --page --html --config builds the two-change payload by itself') do
  with_page_file do |dir, path|
    config = File.join(dir, 'config.json')
    File.write(config, JSON.generate(name: 'Onyx', runtime: { turbo: false, alpine: false }))
    run_cli('describe', 'onyx')

    out, _err, code = run_cli('save', 'onyx', '--page', '/', '--html', path, '--config', config, '--message', 'onyx homepage')
    assert(code == 0, "expected exit 0, got #{code}: #{out}")

    changes = last_args['save']['changes']
    assert(changes.map { |c| [c['op'], c['kind']] } == [%w[put config], %w[put page]], "got #{changes.inspect}")
    assert(changes[1]['key'] == '/', "got #{changes[1].inspect}")
    assert(changes[1]['document']['format'] == 'html', "got #{changes[1]['document'].keys.inspect}")
    assert(changes[1]['document']['metadata']['title'] == 'Onyx — A new way to build the grid.', "got #{changes[1]['document']['metadata'].inspect}")
    assert(changes[1]['document']['body'].include?('{{ asset:assets/onyx-logo-light.svg }}'), 'expected the rewritten body')
    assert(changes[1]['document']['css'] == '.hero { color: red; }', 'expected the inline style carried as page css')
    assert(last_args['save']['message'] == 'onyx homepage', 'expected --message through')
  end
end

check('save carries stylesheets, modules and imports into a config that does not declare them') do
  with_page_file do |dir, path|
    config = File.join(dir, 'config.json')
    File.write(config, JSON.generate(name: 'Onyx'))
    run_cli('describe', 'onyx')
    _out, err, code = run_cli('save', 'onyx', '--page', '/', '--html', path, '--config', config)
    assert(code == 0, 'expected exit 0')

    document = last_args['save']['changes'][0]['document']
    assert(document['stylesheets'] == %w[assets/stealth.css], "got #{document.inspect}")
    assert(document['modules'] == %w[assets/onyx-core-motion.js], "got #{document.inspect}")
    assert(document['imports'] == { 'three' => 'assets/vendor/three/three.module.js' }, "got #{document.inspect}")
    assert(err.include?('carried'), "expected the carry reported on stderr, got #{err.inspect}")
  end
end

check('a config that declares a key wins, even when it declares it empty') do
  with_page_file do |dir, path|
    config = File.join(dir, 'config.json')
    File.write(config, JSON.generate(name: 'Onyx', stylesheets: []))
    run_cli('describe', 'onyx')
    run_cli('save', 'onyx', '--page', '/', '--html', path, '--config', config)
    document = last_args['save']['changes'][0]['document']
    assert(document['stylesheets'] == [], "an explicit empty list was overwritten: #{document.inspect}")
  end
end

check('save --html with no --config says the stylesheets and modules will not load') do
  with_page_file do |_dir, path|
    run_cli('describe', 'onyx')
    _out, err, code = run_cli('save', 'onyx', '--page', '/', '--html', path)
    assert(code == 0, 'expected exit 0')
    assert(last_args['save']['changes'].size == 1, 'expected only the page change')
    assert(err.include?('will not load'), "expected the warning, got #{err.inspect}")
  end
end

check('save --html of a titleless fragment refuses locally until --title is given') do
  with_page_file('<p>hello</p>') do |_dir, path|
    before = requests["#{TOKEN_ONYX} save"]
    out, _err, code = run_cli('save', 'onyx', '--page', '/x', '--html', path)
    assert(code == 1, 'expected a nonzero exit')
    assert(JSON.parse(out)['code'] == 'USAGE', "expected USAGE, got #{out}")
    assert(requests["#{TOKEN_ONYX} save"] == before, 'a page with no title reached the server')

    run_cli('describe', 'onyx')
    _out, _err, code = run_cli('save', 'onyx', '--page', '/x', '--html', path, '--title', 'Hello')
    assert(code == 0, 'expected --title to be enough')
    assert(last_args['save']['changes'][0]['document']['metadata'] == { 'title' => 'Hello' },
      "got #{last_args['save']['changes'][0]['document']['metadata'].inspect}")
  end
end

check('save --html needs --page, and refuses --changes in the same breath') do
  with_page_file do |dir, path|
    before = requests["#{TOKEN_ONYX} save"]
    out, _err, code = run_cli('save', 'onyx', '--html', path)
    assert(code == 1 && JSON.parse(out)['code'] == 'USAGE', "expected USAGE for --html with no --page, got #{out}")

    changes = File.join(dir, 'changes.json')
    File.write(changes, JSON.generate([]))
    out, _err, code = run_cli('save', 'onyx', '--page', '/', '--html', path, '--changes', changes)
    assert(code == 1 && JSON.parse(out)['code'] == 'USAGE', "expected USAGE for both forms at once, got #{out}")
    assert(requests["#{TOKEN_ONYX} save"] == before, 'a malformed save reached the server')
  end
end

# -- stdout is one JSON envelope ----------------------------------------------

check('every envelope-printing subcommand puts exactly one JSON object on stdout') do
  [ %w[describe onyx], %w[diff onyx], %w[history onyx], %w[analytics onyx],
    %w[list-submissions onyx] ].each do |args|
    out, = run_cli(*args)
    assert(out.lines.size == 1, "#{args.first} printed #{out.lines.size} lines on stdout")
    assert(JSON.parse(out).key?('ok'), "#{args.first} printed something that is not the envelope: #{out}")
  end
end

# -- a site token's requests are unchanged ------------------------------------

check('no site-token request anywhere in this run carried a site field') do
  assert(site_on_site_token.empty?,
    "a site token sent a site field: #{site_on_site_token.uniq.join(', ')}")
end

# -- secret redaction ---------------------------------------------------------

check('no bearer token ever appears in anything the CLI printed') do
  [ [ 'acme', TOKEN_ACME ], [ 'other', TOKEN_OTHER ], [ 'onyx', TOKEN_ONYX ] ].each do |slug, token|
    assert(!ALL_OUTPUT.include?(token), "#{slug}'s token leaked into CLI output")
  end
end

check('no bearer token is written to the state file either') do
  raw = File.read(STATE_PATH)
  [ TOKEN_ACME, TOKEN_OTHER, TOKEN_ONYX ].each do |token|
    assert(!raw.include?(token), 'a bearer token was persisted into state.json')
  end
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
