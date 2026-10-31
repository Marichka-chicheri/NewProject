# Non-secret values only. The Google client secret is a sensitive variable of the HCP Terraform
# workspace (google_client_secret); AWS credentials come from the workspace's OIDC role.

project_name = "new-project"
region       = "us-east-1"

# Local dev servers, the CloudFront address (output AppUrl of the frontend stack) and the custom
# domain. After `make deploy-frontend` / `make add-domain` creates a new address, add it here.
app_urls = [
  "http://localhost:5173",
  "http://localhost:3000",
  "https://app.mary-meetings.online",
  "https://d1snn1a6s5yjwe.cloudfront.net",
]

# Google sign-in is enabled in the user pool. The client secret is a sensitive variable of the
# HCP Terraform workspace (google_client_secret), never in this file.
google_client_id = "690629349003-9obkmou9ec7h8u4uunmqdtrkon1792ob.apps.googleusercontent.com"

reports_sender_email    = "fedorenko.pn@ucu.edu.ua"
reports_recipient_email = "fedorenko.pn@ucu.edu.ua"

parser_model = "us.amazon.nova-lite-v1:0"
budget_email = "fedorenko.pn@ucu.edu.ua"
