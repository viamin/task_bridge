module Github
  # A representation of a Github issue
  class Issue
    attr_reader :id, :title, :html_url, :labels, :state

    def initialize(issue)
      @url = issue["url"]
      @html_url = issue["html_url"]
      @id = issue["id"]
      @number = issue["number"]
      @title = issue["title"]
      @labels = issue["labels"].map { |label| label["name"] }
      @state = issue["state"]
    end
  end
end
