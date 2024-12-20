variable "project_id" {
    type = string
}

variable "source_bucket" {
    type = string
}

variable "error_bucket" {
    type = string
}

variable "region" {
    type = string
    default = "us-central1"
}

variable "gtfs_feed_url" {
    type = string
    default = "https://bustime.ttc.ca/gtfsrt/vehicles"
}

variable "dataset_id" {
    type = string
    default = "gtfs"
}

variable "table_id" {
    type = string
    default = "vehicle_locations"
}

