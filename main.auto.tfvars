project            = "slam-lang"
region             = "europe-north1"
zone               = "europe-north1-a"
credentials        = "sa.json"
cloud_run_location = "europe-west1"
gcs_location       = "EU"

ui_dns_name = "slamlang.dev." # DNS managed by Google Domains manually

runner_api_image  = "eu.gcr.io/slam-lang/slam-runner-api:2cf0c55"
example_api_image = "eu.gcr.io/slam-lang/slam-example-api:0ed3d87"
ui_build_revision = "68d8bce"

# Ideas:
# https://cloud.google.com/run/docs/configuring/connecting-vpc#egress
# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_network
