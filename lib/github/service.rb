module Github
  # A service class to connect to the Github API
  class Service
    attr_reader :options, :authentication

    def initialize(options)
      @options = options
      @authentication = Authentication.new(options).authenticate
    end

    # By default Github syncs TO the primary service
    def sync(primary_service)
      tasks = issues_to_sync
      existing_tasks = primary_service.tasks_to_sync
      progressbar = ProgressBar.create(format: "%t: %c/%C |%w>%i| %e ", total: tasks.length, title: "Github issues") if options[:verbose]
      tasks.each do |task|
        if (existing_task = existing_tasks.find { |t| task.title.strip.downcase == t.title.strip.downcase })
          # update the existing task
          primary_service.update_task(existing_task, task, options)
        else
          # add a new task
          primary_service.add_task(task, options)
        end
        progressbar.increment if options[:verbose]
      end
      puts "Synced #{tasks.length} Github issues to #{options[:primary]}" if options[:verbose]
    end

    private

    def authenticated_options
      {
        headers: {
          accept: "application/vnd.github+json",
          authorization: "Bearer #{authentication["access_token"]}"
        }
      }
    end

    def issues_to_sync
      repos = list_repositories.filter { |repo| options[:repositories].include?(repo["full_name"]) }
      issues = repos.map { |repo| list_issues(repo["full_name"]) }.flatten
      labeled_issues = issues.filter { |issue| (issue_labels(issue) & options[:tags]).any? }
      labeled_issues.map { |issue| Issue.new(issue) }
    end

    def list_repositories
      response = HTTParty.get("https://api.github.com/user/repos", authenticated_options)
      JSON.parse(response.body)
    end

    def list_issues(repository)
      response = HTTParty.get("https://api.github.com/repos/#{repository}/issues", authenticated_options)
      JSON.parse(response.body)
    end

    def issue_labels(issue)
      issue["labels"].map { |label| label["name"] }
    end
  end
end
