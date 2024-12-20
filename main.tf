terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.34.0"
    }
  }
}

provider "google" {
  project     = var.project_id
  region      = var.region
}

resource "google_project_service" "cloud_run_api" {
  service = "run.googleapis.com"
}

# ------------------------------------------------------------
# Service accounts & IAM

# SA for the Cloud Run Function to use
resource "google_service_account" "fn_service_account" {
  account_id   = "gcf-sa-gtfs-reader"
  display_name = "GTFS Service Account"
}

# Allow SA to publish to pubsub
resource "google_project_iam_member" "fn_sa_role_pubsub" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.fn_service_account.email}"
}



# Give Cloud Build the ability to build the cloud run function
resource "google_project_iam_member" "compute_builder" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.builder"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# Give PubSub the ability to write to BQ
resource "google_project_iam_member" "pubsub_bq" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}
resource "google_project_iam_member" "pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}
resource "google_project_iam_member" "pubsub_subscriber" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# Give PubSub the ability to trigger CRF
resource "google_project_iam_member" "pubsub_trigger" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}


# ------------------------------------------------------------
# PubSub 

# == Trigger ==
# for triggering the function
resource "google_pubsub_topic" "gtfs_reader_trigger" {
  name = "gtfs-reader-trigger"
}

resource "google_cloud_scheduler_job" "job" {
  name        = "gtfs-trigger"
  description = "Triggers a GTFS data scrape to BQ every minute"
  schedule    = "* * * * *"

  pubsub_target {
    topic_name = google_pubsub_topic.gtfs_reader_trigger.id
    data       = base64encode("ignored")
  }
}

# == Data ==
resource "google_pubsub_schema" "vehicle_location" {
  name = "vehicle_location_schema"
  type = "AVRO"
  definition = <<EOF
{
  "type": "record",
  "name": "VehiclePosition", 
  "fields": [
    {"name": "entity_id", "type": "string"},
    {"name": "vehicle_id", "type": "string"},
    {"name": "trip_id", "type": "string"},
    {"name": "route_id", "type": "string"},
    {"name": "schedule_status", "type": "string"},
    {"name": "latitude", "type": "double"}, 
    {"name": "longitude", "type": "double"},
    {"name": "bearing", "type": "double"},
    {"name": "speed", "type": "double"},
    {"name": "timestamp", "type": "string"},
    {"name": "occupancy_status", "type": "string"},
    {"name": "ingest_timestamp", "type": "string"}
  ]
}  
EOF
}

# GTFS data itself
resource "google_pubsub_topic" "gtfs_data_stream" {
  name = "gtfs-vehicle-locations"
  schema_settings {
    schema = google_pubsub_schema.vehicle_location.id
    encoding = "JSON"
  }
}

# ------------------------------------------------------------
# create dead letter topic
resource "google_pubsub_topic" "dead_letter" {
  name = "gtfs-vehicle-locations-dead-letter"
}

# Storage Bucket for hosting the source code
resource "google_storage_bucket" "dead_letter" {
  name                        = var.error_bucket
  location                    = "US"
  uniform_bucket_level_access = true
}

resource "google_pubsub_subscription" "dead_letter_subscription" {
  name  = "gtfs-dead-letter-subscription"
  topic = google_pubsub_topic.dead_letter.id

  cloud_storage_config {
    bucket = google_storage_bucket.dead_letter.name
  }
  depends_on = [
    google_storage_bucket.dead_letter,
    google_storage_bucket_iam_member.admin,
  ]
}

data "google_project" "project" {
}

resource "google_storage_bucket_iam_member" "admin" {
  bucket = google_storage_bucket.dead_letter.name
  role   = "roles/storage.admin"
  member = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# ------------------------------------------------------------
# Storage Bucket for hosting the source code
resource "google_storage_bucket" "gfc_code_storage" {
  name                        = var.source_bucket
  location                    = "US"
  uniform_bucket_level_access = true
}

# Source of the Cloud Run Function
data "archive_file" "fn_source" {
  type        = "zip"
  output_path = "/tmp/function-source-${filesha256("reader/main.py")}.zip"
  source_dir  = "reader/"
}

# Place the source in the bucket...
resource "google_storage_bucket_object" "code" {
  name   = "function-sourcename-${filesha256("reader/main.py")}.zip"
  bucket = google_storage_bucket.gfc_code_storage.name
  source = data.archive_file.fn_source.output_path # Path to the zipped function source code
  depends_on = [
    data.archive_file.fn_source
  ]
}

# ------------------------------------------------------------
# Cloud Run Function to request feed and push data to PubSub
resource "google_cloudfunctions2_function" "reader_fn" {
  name        = "gtfs-reader-fn"
  location    = var.region
  description = "Reads from a given GTFS feed (path in ENV) and pushes vehicle locations to a pubsub topic"

  build_config {
    runtime     = "python39"
    entry_point = "execute"
    source {
      storage_source {
        bucket = google_storage_bucket.gfc_code_storage.name
        object = google_storage_bucket_object.code.name
      }
    }
  }

  service_config {
    max_instance_count = 3
    min_instance_count = 1
    available_memory   = "256M"
    timeout_seconds    = 60
    environment_variables = {
      GTFS_FEED_URL = var.gtfs_feed_url
      PROJECT_ID = var.project_id
      TOPIC_ID = google_pubsub_topic.gtfs_data_stream.id
    }
    ingress_settings               = "ALLOW_INTERNAL_ONLY"
    all_traffic_on_latest_revision = true
    service_account_email          = google_service_account.fn_service_account.email
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.gtfs_reader_trigger.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }

  depends_on = [
    google_project_iam_member.compute_builder
  ]
}


# ------------------------------------------------------------
# BigQuery and Subscription
resource "google_bigquery_dataset" "gtfs" {
  dataset_id = var.dataset_id
}

resource "google_bigquery_table" "gtfs" {
  table_id   = var.table_id
  dataset_id = google_bigquery_dataset.gtfs.dataset_id

  schema = <<EOF
[
   {
     "name" : "entity_id",
     "type" : "string"
   },
   {
     "name" : "vehicle_id",
     "type" : "string"
   },
   {
     "name" : "trip_id",
     "type" : "string"
   },
   {
     "name" : "route_id",
     "type" : "string"
   },
   {
     "name" : "schedule_status",
     "type" : "string"
   },
   {
     "name" : "latitude",
     "type" : "NUMERIC"
   },
   {
     "name" : "longitude",
     "type" : "NUMERIC"
   },
   {
     "name" : "bearing",
     "type" : "NUMERIC"
   },
   {
     "name" : "speed",
     "type" : "NUMERIC"
   },
   {
     "name" : "timestamp",
     "type" : "timestamp"
   },
   {
     "name" : "occupancy_status",
     "type" : "string",
     "mode": "NULLABLE"
   },
   {
     "name" : "ingest_timestamp",
     "type" : "timestamp"
   }
]
EOF

  deletion_protection = false
}

# Subscription of GTFS data stream topic to BQ
resource "google_pubsub_subscription" "gtfs_to_bq" {
  name  = "gtfs-to-bq-subscription"
  topic = google_pubsub_topic.gtfs_data_stream.id

  bigquery_config {
    table = "${google_bigquery_table.gtfs.project}.${google_bigquery_table.gtfs.dataset_id}.${google_bigquery_table.gtfs.table_id}"
    use_topic_schema = true
    drop_unknown_fields = true
  }

  # configure dead letter policy
  dead_letter_policy {
    dead_letter_topic = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = 10
  }
  
  depends_on = [
    google_project_iam_member.pubsub_bq
  ]
}

