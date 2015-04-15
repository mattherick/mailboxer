class AddSystemAndSystemCaseToMailboxerNotification < ActiveRecord::Migration
  def change
    add_column :mailboxer_notifications, :system, :boolean, :default => true
    add_column :mailboxer_notifications, :system_case, :string
  end
end