# Builds WAMR (scripts/wamr-sources.txt, linux platform) with Stone's
# StoneWasm bridge and runs the test module three times, as the app will.
# Run from the clone root after scripts/fetch-wamr.sh:
#   crystal run scripts/linux-wasm-test.cr
WAMR = "vendor/wasm-micro-runtime-WAMR-2.4.4"
WORK = "build/wamr-test"
abort "WAMR missing: run scripts/fetch-wamr.sh" unless Dir.exists?(WAMR)
Dir.mkdir_p(WORK)

flags = File.read("scripts/wamr-flags.txt").gsub("PLATFORM", "linux").split
flags = flags.map { |f| f.starts_with?("-I") ? "-I#{WAMR}/#{f[2..]}" : f }
flags += ["-DBH_PLATFORM_LINUX", "-DBUILD_TARGET_X86_64", "-D_GNU_SOURCE", "-DWASM_HAVE_MREMAP=1", "-Os", "-w"]
sources = File.read_lines("scripts/wamr-sources.txt").reject { |l| l.blank? || l.starts_with?("#") || l.starts_with?("darwin:") }
sources = sources.map { |s| "#{WAMR}/#{s.gsub("PLATFORM", "linux").gsub("ARCH", "em64")}" }
sources += ["ios/FossilBridge/StoneWasm.c"]

objects = sources.map do |src|
  obj = "#{WORK}/#{File.basename(src).sub(/\.[cs]$/, "")}.o"
  status = Process.run("clang", flags + ["-Iios/FossilBridge", "-c", src, "-o", obj], output: STDOUT, error: STDERR)
  abort "compile failed: #{src}" unless status.success?
  obj
end
def driver(name, objects, flags)
  obj = "#{WORK}/#{name}.o"
  abort "compile failed: #{name}" unless Process.run("clang", flags + ["-Iios/FossilBridge", "-c", "scripts/#{name}.c", "-o", obj], output: STDOUT, error: STDERR).success?
  abort "link failed: #{name}" unless Process.run("clang", objects + [obj, "-o", "#{WORK}/#{name}", "-lm", "-lpthread"], output: STDOUT, error: STDERR).success?
end
driver("linux-wasm-driver", objects, flags)

captured = IO::Memory.new
status = Process.run("#{WORK}/linux-wasm-driver", output: captured, error: STDERR)
text = captured.to_s
puts text
ok = status.success? && text.scan("exit 0").size == 3 &&
     text.scan("Content-Type: text/html\r\n\r\n").size == 3 && text.includes?("WebAssembly runs in Stone")
puts ok ? "linux-wasm-test: PASS" : "linux-wasm-test: FAIL"
exit 1 unless ok

# With a plugin and a feed (crystal run scripts/linux-wasm-test.cr -- PLUGIN.wasm FEED),
# also run the plugin with stand-in answers to its imports: GET, then a POST
# that imports the feed, which must call fetch, query and fossil.
if ARGV.size == 2
  driver("linux-plugin-driver", objects, flags)
  captured = IO::Memory.new
  calls = IO::Memory.new
  status = Process.run("#{WORK}/linux-plugin-driver", ARGV, output: captured, error: calls)
  text = captured.to_s
  log = calls.to_s
  ok = status.success? && text.scan("Status: 200").size == 2 &&
       {"call fetch", "call query", "call fossil"}.all? { |c| log.includes?(c) }
  puts log.lines.first(6).join("\n")
  puts ok ? "linux-plugin-test: PASS" : "linux-plugin-test: FAIL\n#{text}"
  exit ok ? 0 : 1
end
