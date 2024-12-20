# GTFS to BigQuery

This repository demonstrates loading live vehicle location from a GTFS feed and stores the results in a BigQuery table. By default it will ingest all live vehicle feeds from the Toronto Transit Commission (TTC) once per minute.

## Using
### Prerequisites
1. A Google Cloud project with APIs enabled for Cloud Scheduler, Cloud Run, and PubSub
2. Terraform installed

### Deploying
To deploy the infrastructure described by Terraform in this project you must first define the required variables. This can be done via a `terraform.tfvars` file:
```
project_id = "YOUR-PROJECT-ID"
source_bucket = "gtfs-crf-source-bucket"
error_bucket = "gtfs-dead-letter-bucket"
```

With variables in place:
```bash
terraform init
terraform apply
```

## Architecture 
* Cloud Scheduler fires a message once per minute on a pubsub "trigger" topic
* A Cloud Run Function is triggered by messages on the "trigger" topic
* The function (given by the Python function in the `reader` directory) pulls the latest data from the GTFS feed and pushes each vehicle position onto a PubSub "data" topic
* The "data" topic has an associated Avro schema that defines the shape of expected data
* The "data" topic has a BigQuery streaming subscription that pushes all data into a BQ table
* The "data" topic has a deadletter queue that writes all bad messages to a Cloud Storage bucket
