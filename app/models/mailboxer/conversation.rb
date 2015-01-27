class Mailboxer::Conversation < ActiveRecord::Base
  self.table_name = :mailboxer_conversations

  attr_accessible :subject if Mailboxer.protected_attributes?
  
  attr_accessor :body, :recipients_for_new, :create_new_conversation_process

  has_many :opt_outs, :dependent => :destroy, :class_name => "Mailboxer::Conversation::OptOut"
  has_many :messages, :dependent => :destroy, :class_name => "Mailboxer::Message"
  has_many :receipts, :through => :messages,  :class_name => "Mailboxer::Receipt"

  validates :recipients_for_new, :presence => true, :on => :create, :if => Proc.new { |c| c.create_new_conversation_process == true }
  validates :subject, :presence => true,
                      :length => { :maximum => Mailboxer.subject_max_length }
  validates :body, :presence => true, :on => :create, :if => Proc.new { |c| c.create_new_conversation_process == true }

  before_validation :clean

  scope :participant, lambda {|participant|
    where('mailboxer_notifications.type'=> Mailboxer::Message.name).
    order("mailboxer_conversations.updated_at DESC").
    joins(:receipts).merge(Mailboxer::Receipt.recipient(participant)).uniq
  }
  scope :inbox, lambda {|participant|
    participant(participant).merge(Mailboxer::Receipt.inbox.not_trash.not_deleted)
  }
  scope :sentbox, lambda {|participant|
    participant(participant).merge(Mailboxer::Receipt.sentbox.not_trash.not_deleted)
  }
  scope :trash, lambda {|participant|
    participant(participant).merge(Mailboxer::Receipt.trash)
  }
  scope :unread,  lambda {|participant|
    participant(participant).merge(Mailboxer::Receipt.is_unread)
  }
  scope :not_trash,  lambda {|participant|
    participant(participant).merge(Mailboxer::Receipt.not_trash)
  }

  #Mark the conversation as read for one of the participants
  def mark_as_read(participant)
    return unless participant
    receipts_for(participant).mark_as_read
  end

  #Mark the conversation as unread for one of the participants
  def mark_as_unread(participant)
    return unless participant
    receipts_for(participant).mark_as_unread
  end

  #Move the conversation to the trash for one of the participants
  def move_to_trash(participant)
    return unless participant
    receipts_for(participant).move_to_trash
  end

  #Takes the conversation out of the trash for one of the participants
  def untrash(participant)
    return unless participant
    receipts_for(participant).untrash
  end

  #Mark the conversation as deleted for one of the participants
  def mark_as_deleted(participant)
    return unless participant
    deleted_receipts = receipts_for(participant).mark_as_deleted
    if is_orphaned?
      destroy
    else
      deleted_receipts
    end
  end

  #Returns an array of participants
  def recipients
    return [] unless original_message
    Array original_message.recipients
  end

  #Returns an array of participants
  def participants
    recipients
  end

  #Originator of the conversation.
  def originator
    @originator ||= original_message.sender
  end

  #First message of the conversation.
  def original_message
    @original_message ||= messages.order('created_at').first
  end

  #Sender of the last message.
  def last_sender
    @last_sender ||= last_message.sender
  end

  #Last message in the conversation.
  def last_message
    @last_message ||= messages.order('created_at DESC').first
  end

  #Returns the receipts of the conversation for one participants
  def receipts_for(participant)
    Mailboxer::Receipt.conversation(self).recipient(participant)
  end
  
#  def clean_recipients_for(participant)
#    clean_recipients = []
#    self.last_message.recipients.each do |recipient|
#      clean_recipients << recipient if recipient.mailbox.inbox.include?(self)
#    end
#    clean_recipients
#  end

  #Returns the number of messages of the conversation
  def count_messages
    Mailboxer::Message.conversation(self).count
  end

  #Returns true if the messageable is a participant of the conversation
  def is_participant?(participant)
    return false unless participant
    receipts_for(participant).any?
  end

	#Adds a new participant to the conversation
	def add_participant(participant)
		messages.each do |message|
      Mailboxer::ReceiptBuilder.new({
        :notification => message,
        :receiver     => participant,
        :updated_at   => message.updated_at,
        :created_at   => message.created_at
      }).build.save
		end
	end

  #Returns true if the participant has at least one trashed message of the conversation
  def is_trashed?(participant)
    return false unless participant
    receipts_for(participant).trash.count != 0
  end

  #Returns true if the participant has deleted the conversation
  def is_deleted?(participant)
    return false unless participant
    return receipts_for(participant).deleted.count == receipts_for(participant).count
  end

  #Returns true if both participants have deleted the conversation
  def is_orphaned?
    participants.reduce(true) do |is_orphaned, participant|
      is_orphaned && is_deleted?(participant)
    end
  end

  #Returns true if the participant has trashed all the messages of the conversation
  def is_completely_trashed?(participant)
    return false unless participant
    receipts_for(participant).trash.count == receipts_for(participant).count
  end

  def is_read?(participant)
    !is_unread?(participant)
  end

  #Returns true if the participant has at least one unread message of the conversation
  def is_unread?(participant)
    return false unless participant
    receipts_for(participant).not_trash.is_unread.count != 0
  end

  # Creates a opt out object
  # because by default all particpants are opt in
  def opt_out(participant)
    return unless has_subscriber?(participant)
    opt_outs.create(:unsubscriber => participant)
  end

  # Destroys opt out object if any
  # a participant outside of the discussion is, yet, not meant to optin
  def opt_in(participant)
    opt_outs.unsubscriber(participant).destroy_all
  end

  # tells if participant is opt in
  def has_subscriber?(participant)
    !opt_outs.unsubscriber(participant).any?
  end
  
  # add multiple recipients to a conversation
  # => only possible through the originator
  # => generate a new message to inform other members of the conversation about the new recipients
  def add_new_recipients(new_recipients)
    new_added_recipients = []
    new_recipients.each do |new_recipient|
      next if self.is_participant?(new_recipient)
      self.add_participant(new_recipient)
      new_added_recipients << new_recipient
    end
    self.originator.reply_to_conversation(self, "Has added #{new_added_recipients.map(&:display_name).join(", ")} to this conversation...", self.subject, false) unless new_added_recipients.empty?
  end
  
  # remove multiple recipients from a conversation
  # => only possible through the originator
  # => generate a new message to inform other members of the conversation about the deleted recipients
  def remove_recipients(recipients)
    user_ids = self.receipts.map(&:receiver_id).uniq
    removed_recipients = []
    recipients.map(&:to_i).each do |user_id|
      if user_ids.include?(user_id) && user_id != self.originator.id
        user = User.where(:id => user_id).first
        user.delete_conversation(self)
        removed_recipients << user
      end
    end
    self.originator.reply_to_conversation(self, "Has removed #{removed_recipients.map(&:display_name).join(", ")} from this conversation...", self.subject, false) unless removed_recipients.empty?
  end

  protected

  #Use the default sanitize to clean the conversation subject
  def clean
    self.subject = sanitize subject
  end

  def sanitize(text)
    ::Mailboxer::Cleaner.instance.sanitize(text)
  end
end
