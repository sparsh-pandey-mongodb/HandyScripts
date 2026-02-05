#!/usr/bin/env python3
"""
Snapshot History Analyzer for MongoDB Ops Manager
Generates cluster-wise backup duration summaries from snapshotHistory.json
"""

import json
import sys
import os
from datetime import datetime
from collections import defaultdict


def bytes_to_tb(bytes_val):
    """Convert bytes to TB with 2 decimal places"""
    if bytes_val is None or bytes_val == 0:
        return None
    return round(bytes_val / (1024 ** 4), 2)


def seconds_to_hours(seconds):
    """Convert seconds to hours with 1 decimal place"""
    if seconds is None or seconds == 0:
        return None
    return round(seconds / 3600, 1)


def epoch_to_date(epoch_time):
    """Convert epoch timestamp to date string"""
    if epoch_time is None:
        return None
    try:
        return datetime.utcfromtimestamp(epoch_time).strftime('%b %d')
    except (ValueError, OSError):
        return None


def format_speed(speed):
    """Format transfer speed to 1 decimal place"""
    if speed is None or speed == 0:
        return None
    return round(speed, 1)


def get_snapshot_id(snapshot):
    """Extract snapshot identifier from snapshot document"""
    # Try clustershotId first (for sharded clusters)
    if 'clustershotId' in snapshot:
        return snapshot['clustershotId']
    # Fall back to _id
    if '_id' in snapshot:
        _id = snapshot['_id']
        if isinstance(_id, dict) and '$oid' in _id:
            return _id['$oid']
        return str(_id)
    return 'N/A'


def analyze_snapshot(snapshot):
    """
    Analyze a single snapshot entry and extract key metrics.
    Returns None if the snapshot doesn't have detailed metrics.
    """
    # Skip snapshots without detailed metrics (pre-upgrade entries)
    if snapshot.get('dataSize', 0) == 0 and snapshot.get('totalDuration') is None:
        return None

    # Skip failed snapshots
    if snapshot.get('state') != 'COMPLETE':
        return None

    total_duration = snapshot.get('totalDuration')
    if total_duration is None or total_duration == 0:
        return None

    # Get start time for date
    start_time = snapshot.get('startTime', {}).get('time')
    if start_time is None:
        start_time = snapshot.get('lastUpdateTS', {}).get('time')

    # Aggregate metrics from all replica sets in snapshotsMetadata
    snapshots_metadata = snapshot.get('snapshotsMetadata', [])
    if not snapshots_metadata:
        return None

    total_new_bytes = 0
    total_data_upload_duration = 0
    total_transfer_speed_sum = 0
    transfer_speed_count = 0
    all_complete = True
    is_incremental = snapshot.get('incrementalBackup', False)

    for rs_metadata in snapshots_metadata:
        if rs_metadata.get('state') != 'COMPLETE':
            all_complete = False
            continue
  
        new_bytes = rs_metadata.get('numNewBytes', 0) or rs_metadata.get('numNewCompressedBytes', 0)
        total_new_bytes += new_bytes if new_bytes else 0
  
        data_upload = rs_metadata.get('dataBlockUploadDuration', 0)
        total_data_upload_duration += data_upload if data_upload else 0
  
        speed = rs_metadata.get('transferSpeed')
        if speed and speed > 0:
            total_transfer_speed_sum += speed
            transfer_speed_count += 1

    if not all_complete:
        return None

    # Calculate average transfer speed
    avg_transfer_speed = None
    if transfer_speed_count > 0:
        avg_transfer_speed = total_transfer_speed_sum / transfer_speed_count

    return {
        'snapshot_id': get_snapshot_id(snapshot),
        'date': epoch_to_date(start_time),
        'epoch_time': start_time,
        'duration_hours': seconds_to_hours(total_duration),
        'duration_seconds': total_duration,
        'num_new_bytes': total_new_bytes,
        'num_new_bytes_tb': bytes_to_tb(total_new_bytes),
        'data_upload_hours': seconds_to_hours(total_data_upload_duration),
        'data_upload_seconds': total_data_upload_duration,
        'transfer_speed': format_speed(avg_transfer_speed),
        'is_incremental': is_incremental,
        'backup_type': 'Incremental' if is_incremental else 'Full'
    }


def generate_cluster_summary(cluster_name, snapshots):
    """Generate a formatted summary table for a cluster"""

    # Analyze all snapshots
    analyzed = []
    for snapshot in snapshots:
        result = analyze_snapshot(snapshot)
        if result:
            analyzed.append(result)

    if not analyzed:
        return f"\n### Cluster: {cluster_name}\n\nNo detailed backup metrics available for this cluster.\n"

    # Sort by epoch time (most recent first)
    analyzed.sort(key=lambda x: x['epoch_time'] or 0, reverse=True)

    # Generate summary
    output = []
    output.append(f"\n### Cluster: {cluster_name}")
    output.append(f"\nTotal snapshots with detailed metrics: {len(analyzed)}")
    output.append("")

    # Create table header
    output.append("| Date | Duration | Type | numNewBytes (TB) | Data Upload Time | Transfer Speed | clustershotId |")
    output.append("|------|----------|------|------------------|------------------|----------------|---------------|")

    # Add rows
    for entry in analyzed:
        date = entry['date'] or 'N/A'
        duration = f"{entry['duration_hours']} hours" if entry['duration_hours'] else 'N/A'
        backup_type = entry['backup_type']
        new_bytes = f"{entry['num_new_bytes_tb']} TB" if entry['num_new_bytes_tb'] else 'N/A'
        upload_time = f"{entry['data_upload_hours']} hours" if entry['data_upload_hours'] else 'N/A'
        speed = f"{entry['transfer_speed']} MB/s" if entry['transfer_speed'] else 'N/A'
        snapshot_id = entry['snapshot_id']
  
        output.append(f"| {date} | {duration} | {backup_type} | {new_bytes} | {upload_time} | {speed} | {snapshot_id} |")

    # Add statistics
    incremental_snapshots = [s for s in analyzed if s['is_incremental']]
    full_snapshots = [s for s in analyzed if not s['is_incremental']]

    output.append("")
    output.append("#### Statistics")
    output.append("")

    if incremental_snapshots:
        durations = [s['duration_hours'] for s in incremental_snapshots if s['duration_hours']]
        new_bytes = [s['num_new_bytes_tb'] for s in incremental_snapshots if s['num_new_bytes_tb']]
        speeds = [s['transfer_speed'] for s in incremental_snapshots if s['transfer_speed']]
  
        if durations:
            output.append(f"**Incremental Backups ({len(incremental_snapshots)} snapshots):**")
            output.append(f"- Duration: Min {min(durations)} hours, Max {max(durations)} hours, Avg {round(sum(durations)/len(durations), 1)} hours")
        if new_bytes:
            output.append(f"- Data transferred: Min {min(new_bytes)} TB, Max {max(new_bytes)} TB, Avg {round(sum(new_bytes)/len(new_bytes), 2)} TB")
        if speeds:
            output.append(f"- Transfer speed: Min {min(speeds)} MB/s, Max {max(speeds)} MB/s, Avg {round(sum(speeds)/len(speeds), 1)} MB/s")
        output.append("")

    if full_snapshots:
        durations = [s['duration_hours'] for s in full_snapshots if s['duration_hours']]
        speeds = [s['transfer_speed'] for s in full_snapshots if s['transfer_speed']]
  
        if durations:
            output.append(f"**Full Backups ({len(full_snapshots)} snapshots):**")
            output.append(f"- Duration: Min {min(durations)} hours, Max {max(durations)} hours, Avg {round(sum(durations)/len(durations), 1)} hours")
        if speeds:
            output.append(f"- Transfer speed: Min {min(speeds)} MB/s, Max {max(speeds)} MB/s, Avg {round(sum(speeds)/len(speeds), 1)} MB/s")
        output.append("")

    return "\n".join(output)


def generate_output_filename(input_file):
    """Generate output filename based on input filename"""
    base_name = os.path.splitext(os.path.basename(input_file))[0]
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    return f"{base_name}_analysis_{timestamp}.md"


def main():
    """Main function to process snapshotHistory.json"""

    # Check command line arguments
    if len(sys.argv) < 2:
        print("Usage: python3 snapshot_analyzer.py <snapshotHistory.json> [output_file.md]")
        print("\nExample:")
        print("  python3 snapshot_analyzer.py snapshotHistory.json")
        print("  python3 snapshot_analyzer.py snapshotHistory.json custom_report.md")
        print("\nIf output file is not specified, it will be auto-generated based on input filename.")
        sys.exit(1)

    input_file = sys.argv[1]

    # Generate output filename if not provided
    if len(sys.argv) > 2:
        output_file = sys.argv[2]
    else:
        output_file = generate_output_filename(input_file)

    # Load JSON file
    try:
        with open(input_file, 'r') as f:
            snapshots = json.load(f)
    except FileNotFoundError:
        print(f"Error: File '{input_file}' not found.")
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON in '{input_file}': {e}")
        sys.exit(1)

    # Group snapshots by cluster
    clusters = defaultdict(list)

    for snapshot in snapshots:
        cluster_name = snapshot.get('clusterName')
        if cluster_name:
            clusters[cluster_name].append(snapshot)
        else:
            # For non-sharded deployments, use rsId
            rs_id = snapshot.get('rsId', 'Unknown')
            clusters[rs_id].append(snapshot)

    # Generate report
    report = []
    report.append("# Snapshot History Analysis Report")
    report.append(f"\nGenerated: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}")
    report.append(f"\nSource file: {input_file}")
    report.append(f"\nTotal clusters found: {len(clusters)}")
    report.append(f"Total snapshots analyzed: {len(snapshots)}")

    # Generate summary for each cluster
    for cluster_name in sorted(clusters.keys()):
        cluster_snapshots = clusters[cluster_name]
        summary = generate_cluster_summary(cluster_name, cluster_snapshots)
        report.append(summary)

    # Add legend
    report.append("\n---")
    report.append("\n### Metrics Explanation")
    report.append("")
    report.append("- **Duration**: Total time taken for the backup to complete")
    report.append("- **Type**: Incremental (only changed data) or Full (complete backup)")
    report.append("- **numNewBytes**: Total number of new or modified bytes transferred during the backup. This represents the actual data payload that the backup agent reads from the WiredTiger checkpoint and send to the Ops Manager, which then uploads it to the backup storage. Higher values indicate more data changes since the last snapshot, directly resulting in longer backup times.")
    report.append("- **Data Upload Time**: Time spent uploading data blocks to backup storage")
    report.append("- **Transfer Speed**: Average data transfer rate during the backup")
    report.append("- **clustershotId**: Unique identifier for the snapshot entry. Use this to locate the corresponding document in snapshotHistory.json for validation or detailed analysis.")

    # Add validation helper
    report.append("")
    report.append("### How to Validate Entries")
    report.append("")
    report.append("To find a specific snapshot entry in snapshotHistory.json using clustershotId, run:")
    report.append("```bash")
    report.append("jq '.[] | select(.clustershotId == \"<clustershotId>\")' snapshotHistory.json")
    report.append("```")
    report.append("")
    report.append("Example:")
    report.append("```bash")
    report.append("jq '.[] | select(.clustershotId == \"697b04f84c54f11118e99309\")' snapshotHistory.json")
    report.append("```")

    # Write report to file
    final_report = "\n".join(report)

    try:
        with open(output_file, 'w') as f:
            f.write(final_report)
        print(f"Analysis complete!")
        print(f"Input file:  {input_file}")
        print(f"Output file: {output_file}")
        print(f"Clusters analyzed: {len(clusters)}")
        print(f"Total snapshots: {len(snapshots)}")
    except IOError as e:
        print(f"Error writing to output file '{output_file}': {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
#python3 backupSummary.py snapshotHistory.json  
