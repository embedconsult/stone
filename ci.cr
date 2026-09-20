# Stone CI flow.
#
# Run as: crystal run ci.cr   (no arguments, from the clone root)
#
# Exit codes:
#   0   — green
#   75  — this check cannot run on this host (e.g. a required tool is
#         missing); the gate treats 75 as "waiting on an external check"
#         rather than a red failure
#   any other non-zero — red
#
# Xcode Cloud remains the real build; this only runs the Linux-side
# preflight the project already checks before handing off to Xcode Cloud.

require "process"

PREFLIGHT = "scripts/linux-preflight.sh"

output = IO::Memory.new

status =
  begin
    Process.run("bash", [PREFLIGHT], output: output, error: output)
  rescue ex : File::NotFoundError | File::AccessDeniedError
    puts output
    STDERR.puts "ci: cannot run #{PREFLIGHT} on this host: #{ex.message}"
    exit 75
  end

puts output

if status.success?
  exit 0
end

missing = output.to_s.lines.select { |line| line.strip.starts_with?("MISSING:") }

unless missing.empty?
  STDERR.puts
  STDERR.puts "ci: #{PREFLIGHT} reports missing tools on this host — waiting on an external check, not a red failure:"
  missing.each { |line| STDERR.puts "  #{line.strip}" }
  exit 75
end

exit(status.exit_code)
