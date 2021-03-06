class Condition < ActiveRecord::Base
  default_scope :conditions => self.conditions_for_my_region_default_scope

  include UuidMixin
  before_validation :default_name_to_guid, :on => :create

  validates_presence_of     :name, :description, :guid, :modifier, :expression, :towhat
  validates_uniqueness_of   :name, :description, :guid
  # validates_format_of       :name, :with => %r{^[a-z0-9_\-]+$}i,
  #   :allow_nil => true, :message => "must only contain alpha-numeric, underscore and hyphen characters without spaces"
  validates_inclusion_of    :modifier, :in => %w{ allow deny }

  acts_as_miq_taggable
  acts_as_miq_set_member

  include ReportableMixin

  belongs_to :miq_policy
  has_and_belongs_to_many :miq_policies

  CONDITIONS_DIR = File.join(File.expand_path(Rails.root), "product/conditions")

  serialize :expression
  serialize :applies_to_exp

  attr_accessor :reserved

  def applies_to?(rec, inputs={})
    return false if !self.towhat.nil? && rec.class.base_model.name != self.towhat
    return true  if self.applies_to_exp.nil?

    Condition.evaluate(self, rec, inputs, :applies_to_exp)
  end

  def self.conditions
    find(:all).collect {|c| c.expression}
  end

  def self.evaluate(cond, rec, inputs={}, attr=:expression)
    expression = cond.send(attr)
    name = cond.respond_to?(:description) ? cond.description : cond.respond_to?(:name) ? cond.name : nil
    if expression.is_a?(MiqExpression)
      mode = "object"
    else
      mode = expression["mode"]
    end

    case mode
    when "script"
      result = eval(expression["expr"].strip)
    when "tag"
      case expression["include"]
      when "any"
        result = false
      when "all", "none"
        result = true
      else
        raise "condition '#{name}', include value \"#{expression["include"]}\", is invalid. Should be one of \"any, all or none\""
      end

      result = expression["include"] != "any"
      expression["tag"].split.each {|tag|
        # p "rec.is_tagged_with?(#{tag}, :ns => #{expression["ns"]})"
        if rec.is_tagged_with?(tag, :ns => expression["ns"])
          result = true if expression["include"] == "any"
          result = false if expression["include"] == "none"
        else
          result = false if expression["include"] == "all"
        end
      }
    when "tag_expr", "tag_expr_v2", "object"
      case mode
      when "tag_expr"
        expr = expression["expr"]
      when "tag_expr_v2"
        expr = MiqExpression.new(expression["expr"]).to_ruby
      when "object"
        expr = expression.to_ruby
      end

      MiqPolicy.logger.debug("MIQ(condition-eval): Name: #{name}, Expression before substitution: [#{expr.gsub(/\n/, " ")}]")

      subst(expr, rec, inputs)

      MiqPolicy.logger.debug("MIQ(condition-eval): Name: #{name}, Expression after substitution: [#{expr.gsub(/\n/, " ")}]")
      result = self.do_eval(expr)
      MiqPolicy.logger.info("MIQ(condition-eval): Name: #{name}, Expression evaluation result: [#{result}]")
    end
    result
  end

  def self.do_eval(expr)
    if expr =~ /^__start_ruby__\s?__start_context__\s?(.*)\s?__type__\s?(.*)\s?__end_context__\s?__start_script__\s?(.*)\s?__end_script__\s?__end_ruby__$/im
      context, col_type, script = [$1, $2, $3]
      context = MiqExpression.quote(context, col_type)
      result = SafeNamespace.eval_script(script, context)
      raise "Expected return value of true or false from ruby script but instead got result: [#{result.inspect}]" unless result.kind_of?(TrueClass) || result.kind_of?(FalseClass)
    else
      result = eval(expr) ? true : false
    end
    return result
  end

  def self.subst(expr, rec, inputs)
    findexp = /<find>(.+?)<\/find>/im
    if expr =~ findexp
      expr = expr.gsub!(findexp) {|s| _subst_find(rec, inputs, $1.strip)}
      MiqPolicy.logger.debug("MIQ(condition-_subst_find): Find Expression after substitution: [#{expr}]")
    end

    # Make rec class act as miq taggable if not already since the substitution fully relies on virtual tags
    rec.class.acts_as_miq_taggable unless rec.respond_to?("tag_list") || rec.kind_of?(Hash)

    # <mode>/virtual/operating_system/product_name</mode>
    # <mode ref=host>/managed/environment/prod</mode>
    expr.gsub!(/<(value|exist|count|registry)([^>]*)>([^<]+)<\/(value|exist|count|registry)>/im) {|s| _subst(rec, inputs, $2.strip, $3.strip, $1.strip)}

    # <mode /virtual/operating_system/product_name />
    expr.gsub!(/<(value|exist|count|registry)([^>]+)\/>/im) {|s| _subst(rec, inputs, nil, $2.strip, $1.strip)}

    expr
  end

  def self._subst(rec, inputs, opts, tag, mode)
    # $log.info "opts: [#{opts}]"
    # $log.info "tag: [#{tag}]"
    # $log.info "mode: [#{mode}]"
    ohash, ref, object = self.options2hash(opts, rec)

    case mode.downcase
    when "exist"
      ref.nil? ? value = false : value = ref.is_tagged_with?(tag, :ns => "*")
    when "value"
      if ref.kind_of?(Hash)
        value = ref.fetch(tag, "")
      else
        ref.nil? ? value = "" : value = ref.tag_list(:ns => tag)
      end
      value = MiqExpression.quote(value, ohash[:type])
    when "count"
      ref.nil? ? value = 0 : value = ref.tag_list(:ns => tag).length
    when "registry"
      ref.nil? ? value = "" : value = self.registry_data(ref, tag, ohash)
      value = MiqExpression.quote(value, ohash[:type])
    end
    value
  end

  def self.collect_children(ref, methods)
    method = methods.shift

    list = ref.send(method)
    return [] if list.nil?

    result = []
    result = list if methods.empty?
    list = [list] unless list.is_a?(Array)
    list.each {|obj|
      result.concat(collect_children(obj, methods)) unless methods.empty?
    }
    result
  end

  def self._subst_find(rec, inputs, expr)
    MiqPolicy.logger.debug("MIQ(condition-_subst_find): Find Expression before substitution: [#{expr}]")
    searchexp = /<search>(.+)<\/search>/im
    expr =~ searchexp
    search = $1
    MiqPolicy.logger.debug("MIQ(condition-_subst_find): Search Expression before substitution: [#{search}]")

    listexp = /<value([^>]*)>(.+)<\/value>/im
    search =~ listexp
    opts, ref, object = self.options2hash($1, rec)
    methods = $2.split("/")
    methods.shift
    methods.shift
    attr = methods.pop
    l = collect_children(rec, methods)

    return false if l.empty?

    list = l.collect {|obj|
      value = MiqExpression.quote(obj.send(attr), opts[:type])
      value = value.gsub(/\\/, '\&\&') if value.kind_of?(String)
      e = search.gsub(/<value[^>]*>.+<\/value>/im, value.to_s)
      obj if self.do_eval(e)
    }.compact

    MiqPolicy.logger.debug("MIQ(condition-_subst_find): Search Expression returned: [#{list.length}] records")

    checkexp = /<check([^>]*)>(.+)<\/check>/im

    expr =~ checkexp
    checkopts = $1.strip
    check = $2
    checkmode = checkopts.split("=").last.strip.downcase

    MiqPolicy.logger.debug("MIQ(condition-_subst_find): Check Expression before substitution: [#{check}], options: [#{checkopts}]")

    if checkmode == "count"
      e = check.gsub(/<count>/i, list.length.to_s)
      MiqPolicy.logger.debug("MIQ(condition-_subst_find): Check Expression after substitution: [#{e}]")
      result = !!proc { $SAFE = 4; eval(e) }.call
      MiqPolicy.logger.debug("MIQ(condition-_subst_find): Check Expression result: [#{result}]")
      return result
    end

    return false if list.empty?

    check =~ /<value([^>]*)>(.+)<\/value>/im
    raw_opts = $1
    tag = $2
    checkattr = tag.split("/").last.strip

    result = true
    list.each {|obj|
      opts, ref, object = self.options2hash(raw_opts, obj)
      value = MiqExpression.quote(obj.send(checkattr), opts[:type])
      value = value.gsub(/\\/, '\&\&') if value.kind_of?(String)
      e =check.gsub(/<value[^>]*>.+<\/value>/im, value.to_s)
      MiqPolicy.logger.debug("MIQ(condition-_subst_find): Check Expression after substitution: [#{e}]")

      result = self.do_eval(e)

      return true if result && checkmode == "any"
      return false if !result && checkmode == "all"
    }
    MiqPolicy.logger.debug("MIQ(condition-_subst_find): Check Expression result: [#{result}]")
    result
  end

  def self.options2hash(opts, rec)
    ref = rec
    ohash = {}
    unless opts.blank?
      val = nil
      opts.split(",").each {|o|
        attr, val = o.split("=")
        ohash[attr.strip.downcase.to_sym] = val.strip.downcase
      }
      if ohash[:ref] != rec.class.to_s.downcase
        ref = rec.send(val) if val && rec.respond_to?(val)
      end

      if ohash[:object]
        object = val.to_sym
        ref = inputs[object]
      end
    end
    return ohash, ref, object
  end

  def self.registry_data(ref, name, ohash)
    # <registry>HKLM\Software\Microsoft\Windows\CurrentVersion\explorer\Shell Folders\Common AppData</registry> == 'C:\Documents and Settings\All Users\Application Data'
    # <registry>HKLM\Software\Microsoft\Windows\CurrentVersion\explorer\Shell Folders : Common AppData</registry> == 'C:\Documents and Settings\All Users\Application Data'
    return nil unless ref.respond_to?("registry_items")
    if ohash[:key_exists]
      clause = ActiveRecord::Base.connection.adapter_name == "PostgreSQL" ? "name LIKE ? ESCAPE ''" : "name LIKE ?"
      rec = ref.registry_items.find(:first, :conditions => [clause, name + "%"])
      return rec ? true : false
    elsif ohash[:value_exists]
      rec = ref.registry_items.find_by_name(name)
      return rec ? true : false
    else
      rec = ref.registry_items.find_by_name(name)
    end
    return nil unless rec

    # TODO: We can't look at the value type now because we have no visibility to the type at the time the expression is
    # defined so all values come here as strings. Later that will change and this code can be uncommented.
    #
    # case rec.format.to_sym
    # when :REG_DWORD, :REG_DWORD_BIG_ENDIAN, :REG_QWORD
    #   ret = is_numeric?(rec.data) ? rec.data.to_f : rec.data
    # else
    ret = rec.data
    # end
    ret
  end

  def policy_description
    return nil unless self.filename
    cond = Condition.from_file(self.filename)
    cond["policy_description"] unless cond.empty?
  end

  def old_name
    return nil unless self.filename
    cond = Condition.from_file(self.filename)
    cond["old_name"] unless cond.empty?
  end

  def export_to_array
    h = self.attributes
    ["id", "created_on", "updated_on"].each { |k| h.delete(k) }
    return [ self.class.to_s => h ]
  end

  def self.import_from_hash(condition, options={})
    status = {:class => self.name, :description => condition["description"]}
    c = Condition.find_by_guid(condition["guid"])
    msg_pfx = "Importing Condition: guid=[#{condition["guid"]}] description=[#{condition["description"]}]"

    if c.nil?
      c = Condition.new(condition)
      status[:status] = :add
    else
      status[:old_description] = c.description
      c.attributes = condition
      status[:status] = :update
    end

    unless c.valid?
      status[:status]   = :conflict
      status[:messages] = c.errors.full_messages
    end

    msg = "#{msg_pfx}, Status: #{status[:status]}"
    msg += ", Messages: #{status[:messages].join(",")}" if status[:messages]
    unless options[:preview] == true
      MiqPolicy.logger.info(msg)
      c.save!
    else
      MiqPolicy.logger.info("[PREVIEW] #{msg}")
    end

    return c, status
  end

  protected

  def self.sync_from_file(filename)
    cond = self.from_file(filename)
    cond["file_mtime"] = File.mtime(self.path(filename)).utc
    rec = self.find_by_filename(filename)
    if rec.nil?
      name = cond["old_name"] ? cond["old_name"] : cond["name"]
      rec = self.find_by_name(name) if name
    end
    rec ||= self.new

    if rec.file_mtime.nil? || rec.file_mtime.utc < cond["file_mtime"]
      rec.name        = cond["name"]
      rec.filename    = filename
      rec.file_mtime  = cond["file_mtime"]
      rec.modifier    = cond["modifier"]
      rec.expression  = cond["expression"]
      rec.description = cond["description"]
      rec.towhat      = cond["towhat"]
      if rec.new_record?
        $log.info("MIQ(Condition.sync_from_file) Creating Condition [#{cond["name"]}]")
      else
        $log.info("MIQ(Condition.sync_from_file) Updating Condition [#{cond["name"]}]")
      end
      rec.save!
    end
  end

  def self.sync_from_dir
    begin
      # Add missing conditions to model
      Dir.glob(File.join(CONDITIONS_DIR, "*.yml")).each {|f|
        self.sync_from_file(File.basename(f))
      }
      Dir.glob(File.join(CONDITIONS_DIR, "*.xml")).each {|f|
        self.sync_from_file(File.basename(f))
      }
    rescue => err
      MiqPolicy.logger.log_backtrace(err)
    end
  end

  def self.from_file(filename)
    path = self.path(filename)
    file_type = File.extname(filename).split(".").last
    return [] unless File.exists?(path)
    case file_type
    when "yml"
      from_yml(File.read(path))
    when "xml"
      from_xml(File.read(path))
    end
  end

  def self.path(filename)
    File.join(CONDITIONS_DIR, filename)
  end

  def to_yml(p)
    YAML::dump(p)
  end

  def self.from_yml(data)
    cond = YAML::load(data)

    unless cond.has_key?("expression")
      cond["expression"] = cond["rule"]
      cond.delete("rule")
    end

    if cond["expression"]["mode"] == "tag_expr_v2"
      cond["expression"] = MiqExpression.new(cond["expression"]["expr"])
    end
    cond
  end

  def to_xml(p)
    # TODO: convert condition from hash to xml
  end

  def self.from_xml(data)
    cond = {}
    doc=MiqXml.load(data)
    doc.root.attributes.each_key {|k| cond[k]=doc.root.attributes[k]}

    expression_node=doc.find_first("//expr")
    cond["expression"] = {}
    cond["expression"]["mode"] = expression_node.attributes["mode"]

    expr_node=doc.find_first(doc, "//expression/expr")
    handler = ConditionXmlHandler.new
    REXML::Document.parse_stream(expr_node.to_s, handler)
    cond["expression"]["expr"] = handler.expr

    cond
  end

  def self.from_hash(data)
    data
  end

  def self.seed
    MiqRegion.my_region.lock do
      self.sync_from_dir
    end
  end

  module SafeNamespace
    def self.eval_script(script, context)
      log_prefix = "MIQ(SafeNamespace.eval_script)"
      $log.debug("#{log_prefix} Context: [#{context}], Class: [#{context.class.name}]")
      $log.debug("#{log_prefix} Script:\n#{script}")
      begin
        t = Thread.new do
          script = "$SAFE = 3\n#{script}"
          Thread.current["result"] = _eval(context, script)
        end
        to = 20 # allow 20 seconds for script to complete
        Timeout::timeout(to) { t.join }
      rescue TimeoutError => err
        t.exit
        $log.error  "#{log_prefix} The following error occurred during ruby evaluation"
        $log.error  "#{log_prefix}   #{err.class}: #{err.message}"
        raise "Ruby script timed out after #{to} seconds"
      rescue Exception => err
        $log.error  "#{log_prefix} The following error occurred during ruby evaluation"
        $log.error  "#{log_prefix}   #{err.class}: #{err.message}"
        raise "Ruby script raised error [#{err.message}]"
      ensure
        (t["log"] || []).each {|m| $log.info("#{log_prefix} #{m}")} unless t.nil?
      end
      return t["result"]
    end

    def self._eval(context, script)
      eval(script)
    end

    def self.log(msg)
      Thread.current["log"] ||= []
      Thread.current["log"] << "[#{Time.now.utc.iso8601(6).chop}] #{msg}"
    end
  end
end # class Condition

require 'rexml/document'
require 'rexml/streamlistener'

class ConditionXmlHandler
  OPERATORS = {
    "not" => "!",
    "and" => "&&",
    "or"  => "||",
    "equalitymatch" => "==",
    "greaterorequal" => ">=",
    "lessorequal" => "<="
  }

  def expr
    @expr || nil
  end

  def tag_start(name, attrs)
    name = name.downcase

    case name
    when "expr"
      @stack = []
    when "not", "and", "or"
      @stack.push(OPERATORS[name])
    when "equalitymatch", "greaterorequal", "lessorequal"
      subst = attrs["substitute"]
      item = "<#{subst}"
      attrs["ref"] ? item += " ref=#{attrs["ref"]}>" : item += ">"
      item += attrs["name"]
      item += "</#{subst}>"
      @stack.push(OPERATORS[name])
      @stack.push(item)
    when "value"
    end
  end

  def text(value)
    return if value.strip.blank?
    @stack.push(value)
  end

  def tag_end(name)
    name = name.downcase
    case name
    when "expr"
      @expr = @stack.pop
    when "not"
      operand_1 = @stack.pop
      operator = @stack.pop
      @stack.push("#{operator}(#{operand_1})")
    when "and", "or"
      operator = OPERATORS[name]
      list = []
      item = @stack.pop
      until item == operator do
        list.push(item)
        item = @stack.pop
      end
      @stack.push("(#{list.join(" #{operator} ")})")
    when "equalitymatch", "greaterorequal", "lessorequal"
      operand_2 = @stack.pop
      operand_1 = @stack.pop
      operator = @stack.pop
      @stack.push "\"#{operand_1}\" #{operator} \"#{operand_2}\""
    when "value"
    end
  end
end # class ConditionXmlHandler

