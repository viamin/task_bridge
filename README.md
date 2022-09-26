# TaskBridge

Syncs OmniFocus tasks to an external service (and vice versa)

## OmniFocus Setup

This script uses AppleScript on your Mac to talk to OmniFocus. OmniFocus needs to be installed on the computer you're running this script on to work. 

## Google Tasks Setup

Add Google Tasks as an API at https://console.developers.google.com

Create credentials for OAuth client - you can add your Google account as a test account here

Download the JSON credentials to `google_api_client_credentials.json` (or whatever you want, just adjust your `.env` to match)

Run the script and follow the instructions to get an auth token
By default the token will be saved to `~/.config/google/credentials.yaml` - copy it to the script directory or update your `.env` to point to the credentials file. You can use multiple credentials files for different Google accounts, if you desire.
