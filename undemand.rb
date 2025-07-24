#!/usr/bin/env ruby
#
#
#
# ╔═════════════════════════════════════════════════════════════════════════════╗
# ║                      ⟁  OOD_SLURM_GENERATOR.RB    ⟁                        ║
# ║                    ══[ OSC ✦ OOD ✦ SLURM ✦ RUNTIME ]══                      ║. 
# ║                                                                             ║
# ║  ⚙ PURPOSE                                                                  ║
# ║  ▚ Generate a self-contained Slurm batch script from an Open OnDemand       ║
# ║    app repo.                                                                ║
# ║.                                                                            ║
# ║  ▚ Mimics the logic/layout from OSC’s BatchConnect::Template (template.rb). ║
# ║    so that apps behave *exactly* as if run inside OnDemand.                 ║
# ║                                                                             ║
# ║  ⚙ USAGE                                                                    ║
# ║  ▚ Clone the app repo, run this generator script, pipe it to `sbatch`       ║
# ║    or capture to file for preview/deployment.                               ║
# ╚═════════════════════════════════════════════════════════════════════════════╝
#
#
class Object
  def blank?; respond_to?(:empty?) ? !!empty? : !self; end unless method_defined?(:blank?)
  def present?; !blank?; end unless method_defined?(:present?)
end

class OODApp
  TEMPLATE_BASENAMES = %w[before.sh script.sh after.sh].freeze

  DEFAULT_MIN_PORT      = 2000
  DEFAULT_MAX_PORT      = 65_535
  DEFAULT_PASSWORD_SIZE = 32

  def initialize(repo_url, branch: "main")
    @repo_url = repo_url
    @branch   = branch
    @repo_dir = Dir.mktmpdir("ood_app_")
    system("git", "clone", "--depth", "1", "--branch", @branch, @repo_url, @repo_dir, exception: true)
    load_form_yaml
    locate_templates
  end

  

  # -----------------------------------------------------------------------
  def generate_slurm_script(user_opts = {})

    rendered_submit = ERB.new(File.read(@submit_template), trim_mode: "-").result(binding_ctx(ctx))
    submit_spec     = YAML.safe_load(rendered_submit)

    header_lines = assemble_sbatch_header(submit_spec, ctx)
    body         = assemble_body(ctx)

    <<~SCRIPT
      #!/usr/bin/env bash
      #{header_lines.join("\n")}

      #{body}
    SCRIPT
  end

  # -----------------------------------------------------------------------
  private

  # ------ repo helpers ---------------------------------------------------
  def load_form_yaml
    form = %w[form.yml.erb form.yml].find { |f| File.exist?(File.join(@repo_dir, f)) }
    raise "form.yml(.erb) not found" unless form
    content = File.read(File.join(@repo_dir, form))
    content = ERB.new(content, trim_mode: "-").result(binding)
    yaml    = YAML.safe_load(content)
    @attributes = yaml.fetch("attributes", {}) || {}
  end

  def locate_templates
    @submit_template = File.join(@repo_dir, "submit.yml.erb")
    raise "submit.yml.erb missing" unless File.exist?(@submit_template)

    @templates = {}
    TEMPLATE_BASENAMES.each do |base|
      erb = Dir.glob(File.join(@repo_dir, "template", "#{base}.erb")).first || File.join(@repo_dir, "#{base}.erb")
      sh  = Dir.glob(File.join(@repo_dir, "template", base)).first        || File.join(@repo_dir, base)
      path = File.exist?(erb) ? erb : File.exist?(sh) ? sh : nil
      @templates[base] = path if path
    end
  end

  # ------ binding helper -------------------------------------------------
  def binding_ctx(ctx)
    ns = Object.new
    ctx.each { |k, v| ns.define_singleton_method(k) { v } }
    ns.define_singleton_method(:context) { OpenStruct.new(ctx) }
    ns.instance_eval { binding }
  end

  # ------ SBATCH header assembly ----------------------------------------
  def assemble_sbatch_header(submit_spec, ctx)
    lines = Array(submit_spec.dig("batch_connect", "native")).map { |opt| "#SBATCH #{opt}" }
    lines << "#SBATCH --mail-user=#{submit_spec['email']}"           if submit_spec['email'].present?
    lines << "#SBATCH -p #{ctx[:bc_queue]}"                if ctx[:bc_queue]
    lines << "#SBATCH -A #{ctx[:bc_account]}"              if ctx[:bc_account]
    lines << "#SBATCH --job-name=\"#{ctx[:custom_reservation]}\""  if ctx[:custom_reservation]
    lines << "#SBATCH --mail-user=#{ctx[:custom_email_address]}" if ctx[:custom_email_address]
    lines << "#SBATCH --cpus-per-task=#{ctx[:custom_num_cores]}" if ctx[:custom_num_cores]
    lines << "#SBATCH --time=#{ctx[:custom_time]}"               if ctx[:custom_time]
    if ctx[:custom_memory_per_node]
      mem = ctx[:custom_memory_per_node].to_s
      mem += 'G' unless mem =~ /[KMG]$/i
      lines << "#SBATCH --mem=#{mem}"
    end
    if (extra = ctx[:extra_slurm]).present?
      extra.split(/\s*,\s*|\n+/).each { |tok| lines << "#SBATCH #{tok}" }
    end
    lines.uniq
  end

  # ------ Body assembly --------------------------------------------------
  def assemble_body(ctx)
    before = render_part('before.sh', ctx)
    run    = render_part('script.sh', ctx)

    work_dir = ctx[:work_dir] || "$PWD"
    conn_params = ctx[:conn_params] ? JSON.parse(ctx[:conn_params]) : {}
    conn_file = ctx[:conn_file] || File.join(work_dir, "connection.yml")

    <<~BASH
      cd #{work_dir}

      # Export useful connection variables
      export host
      export port

      create_yml () {
        echo "Generating connection YAML file..."
        (
          umask 077
          cat <<EOF > "#{conn_file}"
          #{YAML.dump(conn_params)}
          EOF
        )
      }

      clean_up () {
        echo "Cleaning up..."
        #{render_part('after.sh', ctx).gsub(/^/, '  ')}
        [[ ${SCRIPT_PID} ]] && pkill -P ${SCRIPT_PID} || :
        pkill -P $$
        exit ${1:-0}
      }

      #{bash_helpers}
      source_helpers

      # Set host of current machine
      #{set_host}

      #{before}

      echo "Script starting..."
      (
        #{run}
      ) &
      SCRIPT_PID=$!

      create_yml
      wait ${SCRIPT_PID} || clean_up 1
      clean_up
    BASH
  end

  # ------ Upstream helper definitions -----------------------------------
  def bash_helpers
    <<~HELPERS
      # Source in all the helper functions
      source_helpers () {
        # Generate random integer in range [$1..$2]
        random_number () { shuf -i ${1}-${2} -n 1 }
        export -f random_number

        port_used_python() { python -c "import socket; socket.socket().connect(('$1',$2))" >/dev/null 2>&1 }
        port_used_python3() { python3 -c "import socket; socket.socket().connect(('$1',$2))" >/dev/null 2>&1 }
        port_used_nc(){ nc -w 2 "$1" "$2" < /dev/null > /dev/null 2>&1 }
        port_used_lsof(){ lsof -i :"$2" >/dev/null 2>&1 }
        port_used_bash(){ local bash_supported=$(strings /bin/bash 2>/dev/null | grep tcp); if [ "$bash_supported" == "/dev/tcp/*/*" ]; then (: < /dev/tcp/$1/$2) >/dev/null 2>&1; else return 127; fi }

        # Check if port $1 is in use
        port_used () {
          local port="${1#*:}"
          local host=$((expr "${1}" : '\\(.*\\):' || echo "localhost") | awk 'END{print $NF}')
          local port_strategies=(port_used_nc port_used_lsof port_used_bash port_used_python port_used_python3)
          for strategy in ${port_strategies[@]}; do
            $strategy $host $port
            status=$?
            if [[ "$status" == "0" ]] || [[ "$status" == "1" ]]; then return $status; fi
          done
          return 127
        }
        export -f port_used

        # Find available port in range [$2..$3] for host $1
        find_port () {
          local host="${1:-localhost}"
          local min_port=${2:-#{DEFAULT_MIN_PORT}}
          local max_port=${3:-#{DEFAULT_MAX_PORT}}
          local port_range=($(shuf -i ${min_port}-${max_port}))
          local retries=1
          for ((attempt=0; attempt<=retries; attempt++)); do
            for port in "${port_range[@]}"; do
              if port_used "${host}:${port}"; then continue; fi
              echo "${port}"; return 0;
            done
          done
          echo "error: failed to find available port in range ${min_port}..${max_port}" >&2; return 1
        }
        export -f find_port

        # Wait $2 seconds until port $1 is in use (default 30s)
        wait_until_port_used () {
          local port="${1}"; local time="${2:-30}"
          for ((i=1; i<=time*2; i++)); do
            port_used "${port}"; port_status=$?;
            if [ "$port_status" == "0" ]; then return 0; elif [ "$port_status" == "127" ]; then echo "commands to find port were either not found or inaccessible."; return 127; fi
            sleep 0.5;
          done
          return 1;
        }
        export -f wait_until_port_used

        # Generate random alphanumeric password with $1 characters (default #{DEFAULT_PASSWORD_SIZE})
        create_passwd () ( set +o pipefail; tr -cd 'a-zA-Z0-9' < /dev/urandom 2> /dev/null | head -c${1:-#{DEFAULT_PASSWORD_SIZE}} )
        export -f create_passwd
      }
      export -f source_helpers
    HELPERS
  end

  def set_host
    "host=$(hostname)"
  end

  def render_part(base, ctx)
    path = @templates[base]
    return "" unless path
    content = File.read(path)
    path.end_with?('.erb') ? ERB.new(content, trim_mode: "-").result(binding_ctx(ctx)) : content
  end

  # ------ validation (simplified) ---------------------------------------
def validate_and_merge_opts(user_opts)
  opts   = user_opts.transform_keys(&:to_sym)
  merged = {}

  @attributes.each do |name, spec|
    next unless spec.is_a?(Hash)                # skip malformed entries
    key  = name.to_sym

    # pick user value or default
    val  = opts.key?(key) ? opts[key] : spec['value']

    # if options use [label, value] pairs, translate label → value
    if spec['options'].is_a?(Array) && spec['options'].first.is_a?(Array)
      label_to_value = spec['options'].to_h     # {"Label"=>"value", …}
      val = label_to_value.fetch(val, val)      # map only if label found
    end

    merged[key] = val unless val.nil?
  end

  # carry through any keys the form didn’t declare
  opts.each { |k, v| merged[k] = v unless merged.key?(k) }

  merged
  end
end

# ------------------------------- CLI ----------------------------------------
if $PROGRAM_NAME == __FILE__
  cli = {}
  OptionParser.new do |o|
    o.banner = "Usage: #{$PROGRAM_NAME} -r <repo_url> [param=value ...]"
    o.on("-r", "--repo URL", "Repository URL") { |v| cli[:repo] = v }
    o.on("-h", "--help") { puts o; exit }
  end.parse!
  abort "--repo required" unless cli[:repo]

  params = ARGV.to_h { |p| p.split('=', 2).yield_self { |k, v| [k.to_sym, v] } }
  puts OODApp.new(cli[:repo]).generate_slurm_script(params)
end
