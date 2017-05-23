require 'active_record' unless defined? ActiveRecord

module Paranoia
  def self.included(klazz)
    klazz.extend Query
    klazz.extend Callbacks
  end

  module Query
    def paranoid?
      true
    end

    def with_deleted
      unscope where: paranoia_column
    end

    def only_deleted
      with_deleted.where("#{paranoia_column} <= NOW()")
    end
    alias deleted only_deleted

    def restore(id_or_ids, opts = {})
      ids = Array(id_or_ids).flatten
      any_object_instead_of_id = ids.any? { |id| ActiveRecord::Base === id }
      if any_object_instead_of_id
        ids.map! { |id| ActiveRecord::Base === id ? id.id : id }
        ActiveSupport::Deprecation.warn("You are passing an instance of ActiveRecord::Base to `restore`. " \
                                        "Please pass the id of the object by calling `.id`")
      end
      ids.map { |id| only_deleted.find(id).restore!(opts) }
    end
  end

  module Callbacks
    def self.extended(klazz)
      [:restore, :real_destroy].each do |callback_name|
        klazz.define_callbacks callback_name

        klazz.define_singleton_method("before_#{callback_name}") do |*args, &block|
          set_callback(callback_name, :before, *args, &block)
        end

        klazz.define_singleton_method("around_#{callback_name}") do |*args, &block|
          set_callback(callback_name, :around, *args, &block)
        end

        klazz.define_singleton_method("after_#{callback_name}") do |*args, &block|
          set_callback(callback_name, :after, *args, &block)
        end
      end
    end
  end

  def destroy
    transaction do
      run_callbacks(:destroy) do
        @_disable_counter_cache = deleted?
        result = delete
        next result unless result
        each_counter_cached_associations do |association|
          foreign_key = association.reflection.foreign_key.to_sym
          next if destroyed_by_association && destroyed_by_association.foreign_key.to_sym == foreign_key
          next unless send(association.reflection.name)
          association.decrement_counters
        end
        @_disable_counter_cache = false
        result
      end
    end
  end

  def destroy_at(stamp)
    transaction do
      run_callbacks(:destroy) do
        @_disable_counter_cache = deleted?
        result = delete_at(stamp)
        next result unless result
        each_counter_cached_associations do |association|
          foreign_key = association.reflection.foreign_key.to_sym
          next if destroyed_by_association && destroyed_by_association.foreign_key.to_sym == foreign_key
          next unless send(association.reflection.name)
          association.decrement_counters
        end
        @_disable_counter_cache = false
        result
      end
    end
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord, "#{self.class} is marked as readonly" if readonly?
    if persisted?
      # if a transaction exists, add the record so that after_commit
      # callbacks can be run
      add_to_transaction
      update_columns(paranoia_destroy_attributes)
    elsif !frozen?
      assign_attributes(paranoia_destroy_attributes)
    end
    self
  end

  def delete_at(stamp)
    raise ActiveRecord::ReadOnlyRecord, "#{self.class} is marked as readonly" if readonly?
    if persisted?
      # if a transaction exists, add the record so that after_commit
      # callbacks can be run
      add_to_transaction
      update_columns(
        paranoia_column => stamp.is_a?(String) ? DateTime.parse(stamp) : stamp
      )
    elsif !frozen?
      assign_attributes(
        paranoia_column => stamp.is_a?(String) ? DateTime.parse(stamp) : stamp
      )
    end
    self
  end

  def restore!(opts = {})
    self.class.transaction do
      run_callbacks(:restore) do
        recovery_window_range = get_recovery_window_range(opts)
        if within_recovery_window?(recovery_window_range) && !@attributes.frozen?
          @_disable_counter_cache = !deleted?
          write_attribute paranoia_column, 'infinity'
          update_columns(paranoia_restore_attributes)
          each_counter_cached_associations do |association|
            association.increment_counters if send(association.reflection.name)
          end
          @_disable_counter_cache = false
        end
        restore_associated_records(recovery_window_range) if opts[:recursive]
      end
    end

    self
  end
  alias restore restore!

  def get_recovery_window_range(opts)
    return opts[:recovery_window_range] if opts[:recovery_window_range]
    return unless opts[:recovery_window]
    (deleted_at - opts[:recovery_window]..deleted_at + opts[:recovery_window])
  end

  def within_recovery_window?(recovery_window_range)
    return true unless recovery_window_range
    recovery_window_range.cover?(deleted_at)
  end

  def paranoia_destroyed?
    send(paranoia_column) != Float::INFINITY
  end
  alias :deleted? :paranoia_destroyed?

  def really_destroy!
    transaction do
      run_callbacks(:real_destroy) do
        @_disable_counter_cache = deleted?
        dependent_reflections = self.class.reflections.select do |name, reflection|
          reflection.options[:dependent] == :destroy
        end
        if dependent_reflections.any?
          dependent_reflections.each do |name, reflection|
            association_data = self.send(name)
            # has_one association can return nil
            # .paranoid? will work for both instances and classes
            next unless association_data && association_data.paranoid?
            if reflection.collection?
              next association_data.with_deleted.each(&:really_destroy!)
            end
            association_data.really_destroy!
          end
        end
        write_attribute(paranoia_column, current_time_from_proper_timezone)
        destroy_without_paranoia
      end
    end
  end

  private

  def each_counter_cached_associations
    !@_disable_counter_cache && defined?(super) ? super : []
  end

  def paranoia_restore_attributes
    {
      paranoia_column => 'infinity'
    }.merge(timestamp_attributes_with_current_time)
  end

  def paranoia_destroy_attributes
    {
      paranoia_column => current_time_from_proper_timezone
    }.merge(timestamp_attributes_with_current_time)
  end

  def timestamp_attributes_with_current_time
    timestamp_attributes_for_update_in_model.each_with_object({}) { |attr,hash| hash[attr] = current_time_from_proper_timezone }
  end

  # restore associated records that have been soft deleted when
  # we called #destroy
  def restore_associated_records(recovery_window_range = nil)
    destroyed_associations = self.class.reflect_on_all_associations.select do |association|
      association.options[:dependent] == :destroy
    end

    destroyed_associations.each do |association|
      association_data = send(association.name)

      unless association_data.nil?
        if association_data.paranoid?
          if association.collection?
            association_data.only_deleted.each do |record|
              record.restore(:recursive => true, :recovery_window_range => recovery_window_range)
            end
          else
            association_data.restore(:recursive => true, :recovery_window_range => recovery_window_range)
          end
        end
      end

      if association_data.nil? && association.macro.to_s == 'has_one'
        association_class_name = association.klass.name
        association_foreign_key = association.foreign_key

        if association.type
          association_polymorphic_type = association.type
          association_find_conditions = { association_polymorphic_type => self.class.name.to_s, association_foreign_key => self.id }
        else
          association_find_conditions = { association_foreign_key => self.id }
        end

        association_class = association_class_name.constantize
        if association_class.paranoid?
          association_class.only_deleted.where(association_find_conditions).first
            .try!(:restore, recursive: true, :recovery_window_range => recovery_window_range)
        end
      end
    end

    clear_association_cache if destroyed_associations.present?
  end
end

ActiveSupport.on_load(:active_record) do
  class ActiveRecord::Base
    def self.paranoia_scope
      scoped_quoted_paranoia_column = "#{table_name}.#{paranoia_column}"
      where(scoped_quoted_paranoia_column => (DateTime.now..DateTime::Infinity.new))
    end

    def self.acts_as_paranoid(options = {})
      alias_method :really_destroyed?, :destroyed?
      alias_method :really_delete, :delete
      alias_method :destroy_without_paranoia, :destroy

      include Paranoia
      class_attribute :paranoia_column

      self.paranoia_column = (options[:column] || :deleted_at).to_s

      class << self; alias_method :without_deleted, :paranoia_scope end

      default_scope { paranoia_scope } unless options[:without_default_scope]

      before_restore do
        self.class.notify_observers(:before_restore, self) if self.class.respond_to?(:notify_observers)
      end

      after_restore do
        self.class.notify_observers(:after_restore, self) if self.class.respond_to?(:notify_observers)
      end
    end

    def self.paranoid?
      false
    end

    def paranoid?
      self.class.paranoid?
    end

    private

    def paranoia_column
      self.class.paranoia_column
    end
  end
end

require 'paranoia/rspec' if defined? RSpec

module ActiveRecord
  module Validations
    module UniquenessParanoiaValidator
      def build_relation(klass, *args)
        relation = super
        return relation unless klass.respond_to?(:paranoia_column)
        arel_paranoia_scope = klass.arel_table[klass.paranoia_column].gt(DateTime.now)
        relation.where(arel_paranoia_scope)
      end
    end

    class UniquenessValidator < ActiveModel::EachValidator
      prepend UniquenessParanoiaValidator
    end

    class AssociationNotSoftDestroyedValidator < ActiveModel::EachValidator
      def validate_each(record, attribute, value)
        # if association is soft destroyed, add an error
        record.errors[attribute] << 'has been soft-deleted' if value.present? && value.deleted?
      end
    end
  end
end
