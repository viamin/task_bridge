# TaskBridge

Creates tasks in your productivity apps from items in other services

Originally created to help me sync my Omnifocus tasks to [reclaim.ai](https://reclaim.ai) (which will schedule those tasks using calendar events.) But Omnifocus won't sync directly to reclaim.ai, so I have to sync to an intermediary service, in this case, Google Tasks. But then I thought, what other things would I like to be able to schedule on my calendar automatically? What about Github issues? What about articles I've saved on Instapaper? There are lots of things I would like to see on that calendar (and maybe find out I'm trying to do too many things for the time I have...) So TaskBridge was born. TaskBridge will take a set of services, look for items to sync, and sync them according to tags and labels. For example, if you add a "Omnifocus" label to a Github issue, that will tell TaskBridge to sync that issue to Omnifocus (it will try to find a project matching the Github project name, and add a "Github" tag in Omnifocus.) If you add "Google Tasks" tag to an Omnifocus task, TaskBridge will sync that task from Omnifocus to Google Tasks. Depending on the capabilities of the service, you may also be able to sync the completion state and notes between services.

Run `bundle install` to install dependencies. You may need an account for some of the services to work. Check below for requirements for each service you want to use.

Run `ruby task_bridge.rb --help` to see available command line options.

## Configuration via environment variables

Copy the `.env.example` file to `.env` and change any settings if needed.

Most of the command line options can be configured using an environment variable. The command line option will take precence over the environment variable. If neither the environment variable nor the command line option are set, the default value will be used.

## OmniFocus Setup

This script uses AppleScript on your Mac to talk to OmniFocus. OmniFocus needs to be installed on the computer you're running this script on to work.

## Github Setup

TaskBridge will sync issues and PRs that are assigned to you or that have a label matching what is configured in the `tags` setting. Issues created in Omnifocus will have the "Github" tag applied.

This script will connect to Github using an OAuth token that is created when running for the first time. You'll be prompted with a URL to go to and a code to enter. Enter the code into the URL and you will be logged in.

TaskBridge will only sync tasks from repositories you configure in the `GITHUB_REPOSITORIES` environment variable. Add a comma-separated list of repositories in your `.env` file and issues from those repositories will be checked.

# Reclaim.ai Setup

[reclaim.ai](https://reclaim.ai) doesn't currently have an official external API, so this is a bit of a hack. You will need to copy the access token out of the cookie in your browser to authenticate this.

## Google Tasks Setup

Add Google Tasks as an API at [https://console.developers.google.com](https://console.developers.google.com)

Create credentials for OAuth client - you can add your Google account as a test account here

Download the JSON credentials to `google_api_client_credentials.json` (or whatever you want, just adjust your `.env` to match)

Run the script and follow the instructions to get an auth token
By default the token will be saved to `~/.config/google/credentials.yaml` - copy it to the script directory or update your `.env` to point to the credentials file. You can use multiple credentials files for different Google accounts, if you desire.

## Running automatically (on a Mac)

Scripts are included to run this automatically on a Mac, assuming you have `ruby` installed.

The included launchd plist will run the sync script once an hour between 7am and 10pm daily

* Update the `WorkingDirectory` value in `com.github.viamin.task_bridge.plist` to point to the script directory on your computer
* `cp com.github.viamin.task_bridge.plist ~/Library/LaunchAgents/`
* May need to remove the old one first `launchctl remove com.github.viamin.task_bridge`
* `launchctl load -w ~/Library/LaunchAgents/com.github.viamin.task_bridge.plist`

To run the cleanup task:

* Update the `WorkingDirectory` value in `com.github.viamin.task_bridge.cleanup.plist` to point to the script directory on your computer
* `cp com.github.viamin.task_bridge.cleanup.plist ~/Library/LaunchAgents/`
* May need to remove the old one first `launchctl remove com.github.viamin.task_bridge.cleanup`
* `launchctl load -w ~/Library/LaunchAgents/com.github.viamin.task_bridge.cleanup.plist`
