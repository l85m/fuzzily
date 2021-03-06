require 'fuzzily/trigram'
require 'ostruct'

module Fuzzily
  module Searchable

    def self.included(by)
      case ActiveRecord::VERSION::MAJOR
      when 2 then by.extend Rails2ClassMethods
      when 3 then by.extend Rails3ClassMethods
      when 4 then by.extend Rails4ClassMethods
      end
    end

    private

    def _update_fuzzy!(_o)
      self.send(_o.trigram_association).delete_all
      String.new(self.send(_o.field)).scored_trigrams.each do |trigram, score|
        # The create! with parameters causes a Rails exception for mass assignment
        # self.send(_o.trigram_association).create!(:score => score, :trigram => trigram, :owner_type => self.class.name)
        cfo=self.send(_o.trigram_association).new
        cfo.score = score
        cfo.trigram = trigram
        cfo.owner_type = self.class.name
        cfo.save!
      end
    end


    module ClassMethods
      # fuzzily_searchable <field> [, <field>...] [, <options>]
      def fuzzily_searchable(*fields)
        options = fields.last.kind_of?(Hash) ? fields.pop : {}

        fields.each do |field|
          make_field_fuzzily_searchable(field, options)
        end
      end

      private

      def _find_by_fuzzy(_o, pattern, options={})
        options[:limit] ||= 10
        options[:offset] ||= 0
        # Christer:
        options[:distance_filter] || [] # ex: [["lastname", "Andersson", 0.5], ["firstname", "Bob", 0.5]]
        options[:limit_on_distance] || false # Return all until we reach the distance filter

        trigrams = _o.trigram_class_name.constantize.
          # Christer 2a) Don't apply limit yet
          # limit(options[:limit]).
          offset(options[:offset]).
          for_model(self.name).
          for_field(_o.field.to_s).
          matches_for(pattern)
        # Christer 2b) Send limit param along
        # records = _load_for_ids(trigrams.map(&:owner_id))
        records = _load_for_ids(trigrams.map(&:owner_id), options[:limit], options[:distance_filter], options[:limit_on_distance])
        # order records as per trigram query (no portable way to do this in SQL)
        trigrams.map { |t| records[t.owner_id] }.compact
      end

      # def _load_for_ids_original(ids)
      #   {}.tap do |result|
      #     # Christer 1): breaks if object with id is not found (eg. we're applying fuzzy search to scope)
      #     # find(ids).each { |_r| result[_r.id] = _r }
      #     # Replace with
      #     ids.each{|id|
      #       result[id] = find_by_id(id) if find_by_id(id).present?
      #     }
      #   end
      # end

      def _load_for_ids(ids, limit, filters, limit_on_distance)
        jarow = FuzzyStringMatch::JaroWinkler.create( :native )
        {}.tap do |result|
          ids.each{|id|
            if (needle = find_by_id(id)).present?
              # Trace for Debugging:
              # distances = filters.present? ? filters.collect{|f| jarow.getDistance(needle.read_attribute(f[0]), f[1])} : []
              # Rails.logger.debug "For #{needle.name}: #{distances.inspect}"
              #
              skip = false
              # If we want to check difference against virtual attributes we need to use send and not read_attribute
              # filters.each{|f| break if skip = jarow.getDistance(needle.read_attribute(f[0]), f[1]) < f[2]} if filters.present?
              filters.each{|f| break if skip = jarow.getDistance(needle.send(f[0]), f[1]) < f[2]} if filters.present?
              unless skip
                result[id] = find_by_id(id)
                break if (!limit_on_distance && (limit-=1) == 0)
              end
            end
          }
        end
      end

      def _bulk_update_fuzzy(_o)
        trigram_class = _o.trigram_class_name.constantize

        supports_bulk_inserts  =
          connection.class.name !~ /sqlite/i ||
          connection.send(:sqlite_version) >= '3.7.11'

        _with_included_trigrams(_o).find_in_batches(:batch_size => 100) do |batch|
          inserts = []
          batch.each do |record|
            data = Fuzzily::String.new(record.send(_o.field))
            data.scored_trigrams.each do |trigram, score|
              inserts << sanitize_sql_array(['(?,?,?,?,?)', self.name, record.id, _o.field.to_s, score, trigram])
            end
          end

          # take care of quoting
          c = trigram_class.connection
          insert_sql = %Q{
            INSERT INTO %s (%s, %s, %s, %s, %s)
            VALUES
          } % [
            c.quote_table_name(trigram_class.table_name),
            c.quote_column_name('owner_type'),
            c.quote_column_name('owner_id'),
            c.quote_column_name('fuzzy_field'),
            c.quote_column_name('score'),
            c.quote_column_name('trigram')
          ]

          trigram_class.transaction do
            batch.each { |record| record.send(_o.trigram_association).delete_all }
            break if inserts.empty?

            if supports_bulk_inserts
              trigram_class.connection.insert(insert_sql + inserts.join(", "))
            else
              inserts.each do |insert|
                trigram_class.connection.insert(insert_sql + insert)
              end
            end
          end
        end
      end

      def make_field_fuzzily_searchable(field, options={})
        class_variable_defined?(:"@@fuzzily_searchable_#{field}") and return

        _o = OpenStruct.new(
          :field                  => field,
          :trigram_class_name     => options.fetch(:class_name, 'Trigram'),
          :trigram_association    => "trigrams_for_#{field}".to_sym,
          :update_trigrams_method => "update_fuzzy_#{field}!".to_sym
        )

        _add_trigram_association(_o)

        singleton_class.send(:define_method,"find_by_fuzzy_#{field}".to_sym) do |*args|
          _find_by_fuzzy(_o, *args)
        end

        singleton_class.send(:define_method,"bulk_update_fuzzy_#{field}".to_sym) do
          _bulk_update_fuzzy(_o)
        end

        define_method _o.update_trigrams_method do
          _update_fuzzy!(_o)
        end

        after_save do |record|
          next unless record.send("#{field}_changed?".to_sym)
          record.send(_o.update_trigrams_method)
        end

        class_variable_set(:"@@fuzzily_searchable_#{field}", true)
        self
      end
    end

    module Rails2Rails3ClassMethods
      private

      def _add_trigram_association(_o)
        has_many _o.trigram_association,
          :class_name => _o.trigram_class_name,
          :as         => :owner,
          :conditions => { :fuzzy_field => _o.field.to_s },
          :dependent  => :destroy,
          :autosave   => true
      end

      def _with_included_trigrams(_o)
        self.scoped(:include => _o.trigram_association)
      end
    end

    module Rails2ClassMethods
      include ClassMethods
      include Rails2Rails3ClassMethods

      def self.extended(base)
        base.class_eval do
          named_scope :offset, lambda { |*args| { :offset => args.first } }
        end
      end
    end

    module Rails3ClassMethods
      include ClassMethods
      include Rails2Rails3ClassMethods
    end



    module Rails4ClassMethods
      include ClassMethods

      private

      def _add_trigram_association(_o)
        has_many _o.trigram_association,
          lambda { where(:fuzzy_field => _o.field.to_s) },
          :class_name => _o.trigram_class_name,
          :as         => :owner,
          :dependent  => :delete_all,
          :autosave   => true
      end

      def _with_included_trigrams(_o)
        self.includes(_o.trigram_association)
      end
    end

  end
end
