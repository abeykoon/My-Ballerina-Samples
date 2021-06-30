import ballerina/http;
import ballerina/websub;
import ballerinax/googleapis.sheets as sheets;
import ballerinax/github.webhook as webhook;
import ballerinax/github;
import ballerina/log;
import ballerina/regex;
import ballerina/lang.runtime;

// Github configuration parameters
@display {
    kind: "OAuthConfig",
    provider: "GitHub",
    label: "Set Up GitHub Connection"
}
configurable http:BearerTokenConfig & readonly gitHubTokenConfig = ?;

@display {
    kind: "ConnectionField",
    connectionRef: "gitHubTokenConfig",
    provider: "GitHub",
    operationName: "getUserRepositoryList",
    label: "GitHub Repository URL"
}
configurable string & readonly githubRepoURLs = ?;

@display {
    kind: "WebhookURL",
    label: "Set Up Callback URL for GitHub Webhook"
}
configurable string & readonly githubCallbackURL = ?;

// Google sheets configuration parameters
@display {
    kind: "OAuthConfig",
    provider: "Google Sheets",
    label: "Set Up Google Sheets connection"
}
configurable http:OAuth2RefreshTokenGrantConfig & readonly sheetOauthConfig = ?;

@display {
    kind: "ConnectionField",
    connectionRef: "sheetOauthConfig",
    provider: "Google Sheets",
    operationName: "getAllSpreadsheets",
    label: "Spreadsheet Name"
}
configurable string & readonly spreadsheetId = ?;

@display {
    kind: "ConnectionField",
    connectionRef: "sheetOauthConfig",
    argRef: "spreadsheetId",
    provider: "Google Sheets",
    operationName: "getSheetList",
    label: "Worksheet Name"
}
configurable string & readonly worksheetName = ?;

// Initialize the Github Listener
listener webhook:Listener githubListener = new (8090);
string currentRepoUrl = "";

public function main() returns error? {
    sheets:Client spreadsheetClient = check new ({oauthClientConfig: sheetOauthConfig});
    github:Configuration config = {accessToken: gitHubTokenConfig.token};
    github:Client githubClient = check new (config);

    //clear up the sheet (ramin headers)
    _ = check spreadsheetClient->clearRange(spreadsheetId, worksheetName,"A2:E200");
    
    string[] gitHubRepos = regex:split(githubRepoURLs, ",");
    
    foreach string gitHubRepoUrl in gitHubRepos {
        
        currentRepoUrl = gitHubRepoUrl;

        log:printInfo("Registering listener for repository: " + currentRepoUrl);

        //get existing open pull requests (eg: https://github.com/abeykoon/http-streaming-server")
        string repositoryOwner = regex:split(gitHubRepoUrl, "/")[3]; 
        string repositoryName = regex:split(gitHubRepoUrl, "/")[4];

        //load existing PRs to GSheet
        _ = check writeExistingOpenPullRequestsToGSheet(githubClient, spreadsheetClient, repositoryOwner, repositoryName);

        
        //define service
        var subsriberService = @websub:SubscriberServiceConfig {
            target: [webhook:HUB, currentRepoUrl + "/events/*.json"],
            callback: githubCallbackURL + "/subscriber",
            httpConfig: {auth: gitHubTokenConfig}
        } service object {

            remote function onPullRequestOpened(webhook:PullRequestEvent event) returns error? {
                string repository = event.repository.name;
                string creator = event.sender.login;
                string pullRequestTitle = event.pull_request.title;
                string pullRequestLink = event.pull_request.html_url;
                string createdTime = event.pull_request.created_at;

                sheets:Client spreadsheetClient = check new ({oauthClientConfig: sheetOauthConfig});

                var result = spreadsheetClient->appendRowToSheet(spreadsheetId, worksheetName, [repository, 
                creator, createdTime, pullRequestTitle, pullRequestLink]);
                if result is error {
                    log:printError("Error while writing infor to GSheet", 'error = result);
                }

            }

            remote function onPullRequestClosed(webhook:PullRequestEvent event) returns error? {
                string pullRequestLink = event.pull_request.html_url;
                log:printInfo("pull request closed. url = " + pullRequestLink);
                sheets:Client spreadsheetClient = check new ({oauthClientConfig: sheetOauthConfig});
                sheets:Range allData = check spreadsheetClient->getRange(spreadsheetId, worksheetName, "A:E");
                (int|string|decimal)[][] values = allData.values;
                log:printInfo("Values of spreadsheet" + values.toBalString());
                int rowCount = 0;
                foreach (int|string|decimal)[] row in values {
                    rowCount = rowCount + 1;
                    string pullRequestLinkInRow = <string>row[4];
                    log:printInfo("current pull request link = " + pullRequestLinkInRow);
                    log:printInfo("current pull request link from event = " + pullRequestLink);
                    if (pullRequestLinkInRow.equalsIgnoreCaseAscii(pullRequestLink)) {
                        log:printInfo("Match made");
                        check spreadsheetClient->deleteRowsBySheetName(spreadsheetId, worksheetName, rowCount, 
                        1);
                        break;
                    }
                }
            }
        };

        //attach service
        check githubListener.attach(subsriberService, "/subscriber");

    }

    //start listening
    check githubListener.'start();
    runtime:registerListener(githubListener);

}

function writeExistingOpenPullRequestsToGSheet(github:Client githubClient, sheets:Client spreadsheetClient, 
                                               string repositoryOwner, string repositoryName) returns error? {

    github:PullRequestList openPullRequests = check githubClient->getRepositoryPullRequestList(repositoryOwner, 
    repositoryName, github:PULL_REQUEST_OPEN, 100); //improve to get next page
    foreach github:PullRequest pullRequest in openPullRequests.pullRequests {
        string creator = "Unkown Author";
        var actor = pullRequest?.author;
        if (actor is github:Actor) {
            creator = actor.login;
        }
        string createdTime = pullRequest?.createdAt ?: "Unkown Time";
        string title = pullRequest?.title ?: "Unkonwn Title";
        string link = pullRequest?.url ?: "Unlown Link";
        var result = spreadsheetClient->appendRowToSheet(spreadsheetId, worksheetName, [repositoryName, creator, 
        createdTime, title, link]);
        if (result is error) {
            log:printError("Error while writing infomation to GSheet", 'error = result);
        }

    }
}
