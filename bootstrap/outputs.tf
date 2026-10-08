output "state_bucket_name" {
  description = "Bucket to put in envs/mvp/backend.hcl."
  value       = aws_s3_bucket.state.id
}

output "aws_account_id" {
  description = "Account the bucket was created in."
  value       = data.aws_caller_identity.current.account_id
}
