class Mailboxer::Message < Mailboxer::Notification
  attr_accessible :attachment if Mailboxer.protected_attributes?
  self.table_name = :mailboxer_notifications

  belongs_to :conversation, :class_name => "Mailboxer::Conversation", :validate => true, :autosave => true
  has_many :datafile_associations, :as => :datafileable, :class_name => "DatafileAssociation", :dependent => :destroy
  has_many :datafiles, :through => :datafile_associations, :class_name => "Datafile"
  validates_presence_of :sender
  
  validates :system_case, :inclusion => { :in => ["added", "removed", "left"] }, :allow_blank => true

  class_attribute :on_deliver_callback
  protected :on_deliver_callback
  scope :conversation, lambda { |conversation|
    where(:conversation_id => conversation.id)
  }

  scope :not_system, -> { where(:system => false) }

  mount_uploader :attachment, AttachmentUploader

  class << self
    #Sets the on deliver callback method.
    def on_deliver(callback_method)
      self.on_deliver_callback = callback_method
    end
  end

  #Delivers a Message. USE NOT RECOMENDED.
  #Use Mailboxer::Models::Message.send_message instead.
  def deliver(reply = false, should_clean = true)
    self.clean if should_clean

    #Receiver receipts
    temp_receipts = recipients.map { |r| build_receipt(r, 'inbox') }

    #Sender receipt
    sender_receipt = build_receipt(sender, 'sentbox', true)

    temp_receipts << sender_receipt

    if temp_receipts.all?(&:valid?)
      temp_receipts.each(&:save!)
      Mailboxer::MailDispatcher.new(self, recipients).call

      conversation.touch if reply

      self.recipients = nil

      on_deliver_callback.call(self) if on_deliver_callback
    end
    sender_receipt
  end
  
  def deliver_system_message(person)
    #Receiver receipts
    temp_receipts = recipients.map { |r| build_receipt(r, 'inbox') }

    #Sender receipt
    sender_receipt = build_receipt(sender, 'sentbox', true)

    temp_receipts << sender_receipt
    
    if temp_receipts.all?(&:valid?)
      temp_receipts.each(&:save!)
      Mailboxer::MailDispatcher.new(self, [person]).call unless self.left?
      conversation.touch
      self.recipients = nil
      on_deliver_callback.call(self) if on_deliver_callback
    end
    sender_receipt
  end
  
  # handle newly added datafiles
  # => first add the datafiles to the conversation of the message and the current_message itself
  # => second set the correct permissions for all recipients of the current message
  def handle_new_datafiles(datafile_ids)
    datafiles = self.sender.filemanager.datafiles.where(:id => datafile_ids.map(&:to_i))
    add_datafiles(datafiles)
    add_permissions_for(datafiles)
    self
  end

  # add datafiles to the current message
  def add_datafiles(datafiles)
    conversation = self.conversation
    datafiles.each do |datafile|
      self.datafiles << datafile unless self.datafiles.include?(datafile)
      conversation.datafiles << datafile unless conversation.datafiles.include?(datafile)
    end
  end

  # add new permissions for all datafiles for all recipients
  # do not add a permission if datafiles are public!
  def add_permissions_for(datafiles)
    self.recipients.each do |recipient|
      datafiles.each do |datafile|
        next if datafile.public?
        recipient.add_permission_for(datafile)
      end
    end
  end
  
  def system?
    self.system
  end
  
  def added?
    self.system_case == "added"
  end
  
  def removed?
    self.system_case == "removed"
  end
  
  def left?
    self.system_case == "left"
  end

end
