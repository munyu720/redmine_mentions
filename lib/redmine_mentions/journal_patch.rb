require 'httpclient'

module RedmineMentions
  module JournalPatch
    def self.included(base)
      base.class_eval do
        after_create :send_mail

        def send_mail
          if self.journalized.is_a?(Issue) && self.notes.present?
            issue = self.journalized
            project=self.journalized.project
            users=project.users.to_a.delete_if{|u| (u.type != 'User' || u.mail.empty?)}
            users_regex=users.collect{|u| "#{Setting.plugin_redmine_mentions['trigger']}#{u.login}"}.join('|')
            regex_for_email = '\B('+users_regex+')\b'
            regex = Regexp.new(regex_for_email)
            mentioned_users = self.notes.scan(regex)
            mentioned_users.each do |mentioned_user|
              username = mentioned_user.first[1..-1]
              if user = User.find_by_login(username)
                MentionMailer.notify_mentioning(issue, self, user).deliver

                header = {
                  :project => escape(issue.project),
                  :title => escape(issue),
                  :url => object_url(issue),
                  :author => escape(issue.author),
                  :assigned_to => escape(issue.assigned_to.to_s),
                  :status => escape(issue.status.to_s),
                  :by => escape(journal.user.to_s)
                }

                body = escape journal.notes if journal.notes
                speak room, header, body
              end
            end
          end
        end
      end
    end


    def speak(room, header, body=nil, footer=nil)
      url = 'https://api.chatwork.com/v2/rooms/'
      token = Setting.plugin_redmine_chatwork["token"]
      content = create_body body, header, footer
      reqHeader = {'X-ChatWorkToken' => token}
      endpoint = "#{url}#{room}/messages"

      begin
        client = HTTPClient.new
        client.ssl_config.cert_store.set_default_paths
        client.ssl_config.ssl_version = :auto
        client.post_async(endpoint, "body=#{content}", reqHeader)

      rescue Exception => e
        Rails.logger.info("cannot connect to #{endpoint}")
        Rails.logger.info(e)
      end
    end

    def create_body(body=nil, header=nil, footer=nil)
      result = '[info]'

      if header
        result +=
            "[title]#{'['+header[:status]+']' if header[:status]} #{header[:title] if header[:title]} / #{header[:project] if header[:project]}\n#{header[:url] if header[:url]}\n#{'By: '+header[:by] if header[:by]}#{', Assignee: '+header[:assigned_to] if header[:assigned_to]}#{', Author: '+header[:author] if header[:author]}[/title]"
      end

      if body
        result += body
      end

      if footer
        result += "\n" + footer
      end

      result += '[/info]'

      CGI.escape result
    end

    private
    def escape(msg)
      msg.to_s
    end

    def object_url(obj)
      if Setting.host_name.to_s =~ /\A(https?\:\/\/)?(.+?)(\:(\d+))?(\/.+)?\z/i
        host, port, prefix = $2, $4, $5
        Rails.application.routes.url_for(obj.event_url({
             :host => host,
             :protocol => Setting.protocol,
             :port => port,
             :script_name => prefix
         }))
      else
        Rails.application.routes.url_for(obj.event_url({
             :host => Setting.host_name,
             :protocol => Setting.protocol
         }))
      end
    end

    def check_disabled(proj)
      return nil if proj.blank?

      cf = ProjectCustomField.find_by_name("ChatWork Disabled")
      state = proj.custom_value_for(cf).value rescue nil

      if state == nil
        return false
      end

      if state == '0'
        return false
      end

      true
    end

    def room_for_project(proj)
      return nil if proj.blank?

      cf = ProjectCustomField.find_by_name("ChatWork")

      val = [
          Setting.plugin_redmine_chatwork["room"],
          (proj.custom_value_for(cf).value rescue nil),
      ].find { |v| v.present? }

      rid = val.match(/#!rid\d+/)

      rid[0][5..val.length]
    end

    def detail_to_field(detail)
      if detail.property == "cf"
        key = CustomField.find(detail.prop_key).name rescue nil
        title = key
      elsif detail.property == "attachment"
        key = "attachment"
        title = I18n.t :label_attachment
      else
        key = detail.prop_key.to_s.sub("_id", "")
        title = I18n.t "field_#{key}"
      end

      value = escape detail.value.to_s

      case key
        when "tracker"
          tracker = Tracker.find(detail.value) rescue nil
          value = escape tracker.to_s
        when "project"
          project = Project.find(detail.value) rescue nil
          value = escape project.to_s
        when "status"
          return ''
          #status = IssueStatus.find(detail.value) rescue nil
          #value = escape status.to_s
        when "priority"
          priority = IssuePriority.find(detail.value) rescue nil
          value = escape priority.to_s
        when "category"
          category = IssueCategory.find(detail.value) rescue nil
          value = escape category.to_s
        when "assigned_to"
          user = User.find(detail.value) rescue nil
          value = escape user.to_s
        when "fixed_version"
          version = Version.find(detail.value) rescue nil
          value = escape version.to_s
        when "attachment"
          attachment = Attachment.find(detail.prop_key) rescue nil
          value = "<#{object_url attachment}|#{escape attachment.filename}>" if attachment
        when "parent"
          issue = Issue.find(detail.value) rescue nil
          value = "<#{object_url issue}|#{escape issue}>" if issue
      end

      value = "-" if value.empty?
      result = "\n#{title}: #{value}"
      result
    end

  end
end
