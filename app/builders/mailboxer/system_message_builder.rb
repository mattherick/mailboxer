class Mailboxer::SystemMessageBuilder < Mailboxer::BaseBuilder

  protected

  def klass
    Mailboxer::Message
  end

end