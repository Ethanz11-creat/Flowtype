# Behavioral CLI regression: compile the actual production @main and inject only
# a synthetic Foundation home/cache boundary. No source rewriting or product build.
require 'fileutils'
require 'open3'
require 'securerandom'

repo = File.expand_path('../..', __dir__)
scratch = ARGV.fetch(0)
abort 'supply absolute scratch below repository build/' unless scratch.start_with?(repo + '/build/')
FileUtils.mkdir_p(scratch)
run = File.join(scratch, 'cli-input-' + SecureRandom.uuid)
FileUtils.mkdir_p(run)
tool = File.join(run, 'packaging-cli')
compile = ['/usr/bin/swiftc', *%w[BoundedProcess.swift ArtifactPackaging.swift ArtifactPackagingCLI.swift ArtifactPackagingCLIInputFixture.swift].map { |n| File.join(__dir__, n) }, '-o', tool]
stdout, stderr, status = Open3.capture3(*compile, chdir: repo)
File.write(File.join(run, 'compile.stdout'), stdout)
File.write(File.join(run, 'compile.stderr'), stderr)
abort "CLI fixture compilation failed: #{stderr}" unless status.success?

home = File.join(run, 'synthetic home')
shader = File.join(home, '.cache/uv/archive-v0/synthetic/mlx/lib/mlx.metallib')
FileUtils.mkdir_p(File.dirname(shader))
File.binwrite(shader, 'MTLB' + "\0" * (1_048_576 - 4))
FileUtils.mkdir_p(File.join(home, '.cache/pip'))
fixture = File.join(run, 'repo with spaces')
FileUtils.mkdir_p(fixture)
# Deliberately invalid Git metadata prevents all real build/sign/provider work if
# the CLI incorrectly accepts fallback. Git global/system configuration is disabled
# by the real packagingCommand adapter.
File.write(File.join(fixture, '.git'), "synthetic invalid git metadata\n")
passed = 0
failed = 0
check = lambda do |value, label|
  if value
    passed += 1
    puts "PASS: #{label}"
  else
    failed += 1
    puts "FAIL: #{label}"
  end
end
[
  ['missing', nil, ['build', fixture], 1, "FlowType packaging: shaderInvalid\n"],
  ['empty', '', ['build', fixture], 1, "FlowType packaging: shaderInvalid\n"],
  ['explicit', shader, ['build', fixture], 1, "FlowType packaging: sourceInvalid\n"],
  ['extra-argument', shader, ['build', fixture, 'unexpected'], 64, "FlowType packaging: usage\n"]
].each do |name, input, args, expected_exit, expected_error|
  trace = File.join(run, name + '.cache-trace')
  File.write(trace, '')
  env = {'MLX_METALLIB_PATH' => input, 'PACKAGING_TEST_HOME' => home, 'PACKAGING_TEST_TRACE' => trace}
  out, err, result = Open3.capture3(env, tool, *args, chdir: fixture)
  File.write(File.join(run, name + '.stdout'), out)
  File.write(File.join(run, name + '.stderr'), err)
  File.write(File.join(run, name + '.exit'), result.exitstatus.to_s + "\n")
  check.call(result.exitstatus == expected_exit && err == expected_error,
             "#{name}: actual CLI exit#{expected_exit} / #{expected_error.strip}")
  check.call(File.read(trace).empty?, "#{name}: no user-cache enumeration")
  check.call(out.empty?, "#{name}: no published candidate")
end
puts "CLI input regression: #{passed} passed, #{failed} failed"
puts "Raw evidence: #{run}"
exit(failed.zero? ? 0 : 1)
