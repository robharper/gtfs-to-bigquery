#
import json
import time
import requests
import os
from datetime import datetime, timezone
from google.transit import gtfs_realtime_pb2
from google.cloud import pubsub_v1

# Protobuf
OccStatus = gtfs_realtime_pb2.VehiclePosition.OccupancyStatus
ScheduleRel = gtfs_realtime_pb2.TripDescriptor.ScheduleRelationship

# Get setup from ENV
topic_id = os.environ.get("TOPIC_ID")
gtfs_url = os.environ.get("GTFS_URL", "https://bustime.ttc.ca/gtfsrt/vehicles")

publisher = pubsub_v1.PublisherClient()


# Execute
def execute(*args, **kwargs):
    now_utc = datetime.now(timezone.utc)
    now_str = now_utc.isoformat()

    response = requests.get(gtfs_url)
    if response.status_code != 200:
        print(f"Received an error from the GTFS feed URL {gtfs_url}, status {response.status_code}")
        return

    try:
        feed = gtfs_realtime_pb2.FeedMessage()
        feed.ParseFromString(response.content)
        results = []
        for entity in feed.entity:
            try:
                update_time = datetime.fromtimestamp(entity.vehicle.timestamp, timezone.utc)
                payload = {
                    "entity_id": entity.id,
                    "vehicle_id": entity.vehicle.vehicle.id,
                    "trip_id": entity.vehicle.trip.trip_id,
                    "route_id": entity.vehicle.trip.route_id,
                    "schedule_status": ScheduleRel.Name(entity.vehicle.trip.schedule_relationship),
                    "latitude": entity.vehicle.position.latitude,
                    "longitude": entity.vehicle.position.longitude,
                    "bearing": entity.vehicle.position.bearing,
                    "speed": entity.vehicle.position.speed,
                    "timestamp":update_time.isoformat(),
                    "occupancy_status": OccStatus.Name(entity.vehicle.occupancy_status),
                    "ingest_timestamp": now_str
                }

                # Convert the JSON payload to a bytestring
                data_str = json.dumps(payload)
                data_bytes = data_str.encode("utf-8")

                # Publish the message
                future = publisher.publish(topic_id, data_bytes)
                results.append(future.result())
            except Exception as entity_err:
                print(f"Skipping record due to error {entity_err}")       

        print(f"Delivered {len(results)} messages") 
    except Exception as err:
        print(f"Received error {err} parsing the feed")

