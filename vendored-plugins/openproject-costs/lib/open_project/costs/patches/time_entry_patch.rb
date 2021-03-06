#-- copyright
# OpenProject Costs Plugin
#
# Copyright (C) 2009 - 2014 the OpenProject Foundation (OPF)
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# version 3.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#++

# Patches Redmine's Users dynamically.
module OpenProject::Costs::Patches::TimeEntryPatch
  def self.included(base) # :nodoc:
    base.extend(ClassMethods)

    base.send(:include, InstanceMethods)

    # Same as typing in the class t.update_costs
    base.class_eval do
      belongs_to :rate, -> { where(type: ['HourlyRate', 'DefaultHourlyRate']) }, class_name: 'Rate'

      before_save :update_costs

      def self.visible_condition(user, table_alias: nil, project: nil)
        options = {}
        options[:project_alias] = table_alias if table_alias
        options[:project] = project if project

        %{ (#{Project.allowed_to_condition(user,
                                           :view_time_entries,
                                           options)} OR
             (#{Project.allowed_to_condition(user,
                                             :view_own_time_entries,
                                             options)} AND
              #{TimeEntry.table_name}.user_id = #{user.id})) }
      end

      scope :visible_costs, lambda{|*args|
        user = args.first || User.current
        project = args[1]

        view_hourly_rates = %{ (#{Project.allowed_to_condition(user, :view_hourly_rates, project: project)} OR
                                (#{Project.allowed_to_condition(user, :view_own_hourly_rate, project: project)} AND #{TimeEntry.table_name}.user_id = #{user.id})) }
        view_time_entries = TimeEntry.visible_condition(user, project: project)

        includes(:project, :user)
          .where([view_time_entries, view_hourly_rates].join(' AND '))
      }

      def self.costs_of(work_packages:)
        # N.B. Because of an AR quirks the code below uses statements like
        #   where(work_package_id: ids)
        # You would expect to be able to simply write those as
        #   where(work_package: work_packages)
        # However, AR (Rails 4.2) will not expand :includes + :references inside a subquery,
        # which will render the query invalid. Therefore we manually extract the IDs in a separate (pluck) query.
        ids = if work_packages.respond_to?(:pluck)
                work_packages.pluck(:id)
              else
                Array(work_packages).map { |wp| wp.id }
              end
        TimeEntry.where(work_package_id: ids)
          .joins(work_package: :project)
          .visible_costs
          .sum("COALESCE(#{TimeEntry.table_name}.overridden_costs,
                         #{TimeEntry.table_name}.costs)").to_f
      end
    end
  end

  module ClassMethods
    def update_all(updates, conditions = nil, options = {})
      # instead of a update_all, perform an individual update during work_package#move
      # to trigger the update of the costs based on new rates
      if conditions.respond_to?(:keys) && conditions.keys == [:work_package_id] && updates =~ /^project_id = ([\d]+)$/
        project_id = $1
        time_entries = TimeEntry.where(conditions)
        time_entries.each do |entry|
          entry.project_id = project_id
          entry.save!
        end
      else
        super
      end
    end
  end

  module InstanceMethods
    def real_costs
      # This methods returns the actual assigned costs of the entry
      overridden_costs || costs || calculated_costs
    end

    def calculated_costs(rate_attr = nil)
      rate_attr ||= current_rate
      hours * rate_attr.rate
    rescue
      0.0
    end

    def update_costs(rate_attr = nil)
      rate_attr ||= current_rate
      if rate_attr.nil?
        self.costs = 0.0
        self.rate = nil
        return
      end

      self.costs = calculated_costs(rate_attr)
      self.rate = rate_attr
    end

    def update_costs!(rate_attr = nil)
      update_costs(rate_attr)
      self.save!
    end

    def current_rate
      user.rate_at(spent_on, project_id)
    end

    def visible_by?(usr)
      usr.allowed_to?(:view_time_entries, project) ||
        (user_id == usr.id && usr.allowed_to?(:view_own_time_entries, project))
    end

    def costs_visible_by?(usr)
      usr.allowed_to?(:view_hourly_rates, project) ||
        (user_id == usr.id && usr.allowed_to?(:view_own_hourly_rate, project))
    end
  end
end
