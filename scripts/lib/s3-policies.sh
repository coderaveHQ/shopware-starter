#!/usr/bin/env bash
# Deterministic least-privilege policies for IONOS contract-owned buckets.

render_runtime_bucket_policy() {
  local destination="$1" bucket="$2" runtime_user_id="$3" reader_user_id="$4" public_read="$5"
  is_valid_bucket "$bucket" || die "Ungültiger Bucket für Policy: $bucket"
  is_valid_contract_user_id "$runtime_user_id" || die "Ungültige Runtime Contract User ID."
  is_valid_contract_user_id "$reader_user_id" || die "Ungültige Backup Reader Contract User ID."
  is_valid_bool "$public_read" || die "public_read muss true oder false sein."
  python3 - "$destination" "$bucket" "$runtime_user_id" "$reader_user_id" "$public_read" <<'PY'
import json
import pathlib
import sys

destination, bucket, runtime_id, reader_id, public_read = sys.argv[1:]
bucket_arn = f"arn:aws:s3:::{bucket}"
object_arn = f"{bucket_arn}/*"

statements = [
    {
        "Sid": "RuntimeBucketAccess",
        "Effect": "Allow",
        "Principal": {"AWS": f"arn:aws:iam:::user/{runtime_id}"},
        "Action": ["s3:GetBucketLocation", "s3:ListBucket"],
        "Resource": bucket_arn,
    },
    {
        "Sid": "RuntimeObjectAccess",
        "Effect": "Allow",
        "Principal": {"AWS": f"arn:aws:iam:::user/{runtime_id}"},
        "Action": ["s3:DeleteObject", "s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:PutObjectAcl"],
        "Resource": object_arn,
    },
    {
        "Sid": "BackupReaderBucketAccess",
        "Effect": "Allow",
        "Principal": {"AWS": f"arn:aws:iam:::user/{reader_id}"},
        "Action": ["s3:GetBucketLocation", "s3:ListBucket"],
        "Resource": bucket_arn,
    },
    {
        "Sid": "BackupReaderObjectAccess",
        "Effect": "Allow",
        "Principal": {"AWS": f"arn:aws:iam:::user/{reader_id}"},
        "Action": ["s3:GetObject", "s3:GetObjectVersion"],
        "Resource": object_arn,
    },
]

if public_read == "true":
    statements.append(
        {
            "Sid": "PublicRead",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": object_arn,
        }
    )

path = pathlib.Path(destination)
path.write_text(json.dumps({"Version": "2012-10-17", "Statement": statements}, indent=2) + "\n")
path.chmod(0o600)
PY
}

render_backup_bucket_policy() {
  local destination="$1" bucket="$2" writer_user_id="$3"
  is_valid_bucket "$bucket" || die "Ungültiger Bucket für Policy: $bucket"
  is_valid_contract_user_id "$writer_user_id" || die "Ungültige Backup Writer Contract User ID."
  python3 - "$destination" "$bucket" "$writer_user_id" <<'PY'
import json
import pathlib
import sys

destination, bucket, writer_id = sys.argv[1:]
bucket_arn = f"arn:aws:s3:::{bucket}"
object_arn = f"{bucket_arn}/*"
policy = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "BackupWriterBucketAccess",
            "Effect": "Allow",
            "Principal": {"AWS": f"arn:aws:iam:::user/{writer_id}"},
            "Action": ["s3:GetBucketLocation", "s3:ListBucket"],
            "Resource": bucket_arn,
        },
        {
            "Sid": "BackupWriterObjectAccess",
            "Effect": "Allow",
            "Principal": {"AWS": f"arn:aws:iam:::user/{writer_id}"},
            "Action": ["s3:DeleteObject", "s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"],
            "Resource": object_arn,
        },
    ],
}
path = pathlib.Path(destination)
path.write_text(json.dumps(policy, indent=2) + "\n")
path.chmod(0o600)
PY
}
