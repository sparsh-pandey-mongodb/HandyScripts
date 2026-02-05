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


def bytes_to_human_readable(bytes_val):
    """Convert bytes to human readable format with appropriate unit"""
    if bytes_val is None or bytes_val == 0:
        return None, None

    units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB']
    unit_index = 0
    value = float(bytes_val)

    while value >= 1024 and unit_index < len(units) - 1:
        value /= 1024
        unit_index += 1

    return round(value, 2), units[unit_index]


def seconds_to_human_readable(seconds):
    """Convert seconds to human readable format with appropriate unit"""
    if seconds is None or seconds == 0:
        return None, None

    if seconds < 60:
        value = round(seconds, 1)
        unit = 'second' if value == 1 else 'seconds'
        return value, unit
    elif seconds < 3600:
        value = round(seconds / 60, 1)
        unit = 'minute' if value == 1 else 'minutes'
        return value, unit
    else:
        value = round(seconds / 3600, 1)
        unit = 'hour' if value == 1 else 'hours'
        return value, unit



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
    # Skip failed snapshots
    if snapshot.get('state') != 'COMPLETE':
        return None

    total_duration = snapshot.get('totalDuration')

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
    has_metrics = False
    is_incremental = snapshot.get('incrementalBackup', False)

    for rs_metadata in snapshots_metadata:
        if rs_metadata.get('state') != 'COMPLETE':
            all_complete = False
            continue

        # Check if this metadata has actual metrics
        if rs_metadata.get('numNewBytes') or rs_metadata.get('numNewCompressedBytes') or rs_metadata.get('dataBlockUploadDuration') or rs_metadata.get('transferSpeed'):
            has_metrics = True

        # Only use numNewBytes - don't substitute with other values
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

    # Skip entries without meaningful metrics
    if not has_metrics and total_duration is None:
        return None

    # Calculate average transfer speed
    avg_transfer_speed = None
    if transfer_speed_count > 0:
        avg_transfer_speed = total_transfer_speed_sum / transfer_speed_count

    # Convert to human readable formats
    duration_val, duration_unit = seconds_to_human_readable(total_duration)
    new_bytes_val, new_bytes_unit = bytes_to_human_readable(total_new_bytes)
    upload_val, upload_unit = seconds_to_human_readable(total_data_upload_duration)

    return {
        'snapshot_id': get_snapshot_id(snapshot),
        'date': epoch_to_date(start_time),
        'epoch_time': start_time,
        'duration_val': duration_val,
        'duration_unit': duration_unit,
        'duration_seconds': total_duration,
        'num_new_bytes': total_new_bytes,
        'num_new_bytes_val': new_bytes_val,
        'num_new_bytes_unit': new_bytes_unit,
        'data_upload_val': upload_val,
        'data_upload_unit': upload_unit,
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
    output.append("| Date | Duration | Type | numNewBytes | Data Upload Time | Transfer Speed | clustershotId |")
    output.append("|------|----------|------|-------------|------------------|----------------|---------------|")

    # Add rows
    for entry in analyzed:
        date = entry['date'] or 'N/A'

        if entry['duration_val'] is not None:
            duration = f"{entry['duration_val']} {entry['duration_unit']}"
        else:
            duration = 'N/A'

        backup_type = entry['backup_type']

        if entry['num_new_bytes_val'] is not None:
            new_bytes = f"{entry['num_new_bytes_val']} {entry['num_new_bytes_unit']}"
        else:
            new_bytes = 'N/A'

        if entry['data_upload_val'] is not None:
            upload_time = f"{entry['data_upload_val']} {entry['data_upload_unit']}"
        else:
            upload_time = 'N/A'

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
        durations = [s['duration_seconds'] for s in incremental_snapshots if s['duration_seconds']]
        new_bytes = [s['num_new_bytes'] for s in incremental_snapshots if s['num_new_bytes']]
        speeds = [s['transfer_speed'] for s in incremental_snapshots if s['transfer_speed']]

        output.append(f"**Incremental Backups ({len(incremental_snapshots)} snapshots):**")

        if durations:
            min_dur_val, min_dur_unit = seconds_to_human_readable(min(durations))
            max_dur_val, max_dur_unit = seconds_to_human_readable(max(durations))
            avg_dur_val, avg_dur_unit = seconds_to_human_readable(sum(durations)/len(durations))
            output.append(f"- Duration: Min {min_dur_val} {min_dur_unit}, Max {max_dur_val} {max_dur_unit}, Avg {avg_dur_val} {avg_dur_unit}")

        if new_bytes:
            min_bytes_val, min_bytes_unit = bytes_to_human_readable(min(new_bytes))
            max_bytes_val, max_bytes_unit = bytes_to_human_readable(max(new_bytes))
            avg_bytes_val, avg_bytes_unit = bytes_to_human_readable(sum(new_bytes)/len(new_bytes))
            output.append(f"- Data transferred (numNewBytes): Min {min_bytes_val} {min_bytes_unit}, Max {max_bytes_val} {max_bytes_unit}, Avg {avg_bytes_val} {avg_bytes_unit}")

        if speeds:
            output.append(f"- Transfer speed: Min {min(speeds)} MB/s, Max {max(speeds)} MB/s, Avg {round(sum(speeds)/len(speeds), 1)} MB/s")
        output.append("")

    if full_snapshots:
        durations = [s['duration_seconds'] for s in full_snapshots if s['duration_seconds']]
        speeds = [s['transfer_speed'] for s in full_snapshots if s['transfer_speed']]

        output.append(f"**Full Backups ({len(full_snapshots)} snapshots):**")

        if durations:
            min_dur_val, min_dur_unit = seconds_to_human_readable(min(durations))
            max_dur_val, max_dur_unit = seconds_to_human_readable(max(durations))
            avg_dur_val, avg_dur_unit = seconds_to_human_readable(sum(durations)/len(durations))
            output.append(f"- Duration: Min {min_dur_val} {min_dur_unit}, Max {max_dur_val} {max_dur_unit}, Avg {avg_dur_val} {avg_dur_unit}")

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
    report.append("- **numNewBytes**: Total number of new or modified bytes transferred during an incremental backup. This represents the actual data payload that the backup agent reads from the WiredTiger checkpoint and sends to the Ops Manager, which then uploads it to the backup storage. Higher values indicate more data changes since the last snapshot, directly resulting in longer backup times. This field is not applicable (N/A) for Full backups.")
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
    report.append("For replica set snapshots (without clustershotId), use _id:")
    report.append("```bash")
    report.append("jq '.[] | select(._id == \"<_id>\")' snapshotHistory.json")
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
