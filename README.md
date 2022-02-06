# SLAM terraform configs

## Running

1. Download a suitable SA JSON to the directory root and call it `sa.json`.
2. Set up Node.js 16 local environment (used with GCP Cloud Functions) & `gcloud` CLI
4. Add secrets to `secrets.auto.tfvars`

```
(cd deploy-ui-gcs && npm ci)
export GOOGLE_APPLICATION_CREDENTIALS="$(pwd)/sa.json"
terraform init
terraform apply
```
