locals {
  stream_name         = "${var.prefix}_streamalert_alert_delivery"
  bucket_arn          = "arn:aws:s3:::${var.prefix}-streamalerts"
  alerts_location     = "s3://${var.prefix}-streamalerts/alerts"
  ser_de_params_key   = var.store_format == "parquet" ? "serialization.format" : "ignore.malformed.json"
  ser_de_params_value = var.store_format == "parquet" ? "1" : "true"
}

resource "aws_kinesis_firehose_delivery_stream" "streamalerts" {
  name        = local.stream_name
  destination = var.store_format == "parquet" ? "extended_s3" : "s3"

  // AWS Firehose Stream for Alerts to S3 and saved in JSON format
  dynamic "s3_configuration" {
    for_each = var.store_format == "parquet" ? [] : [var.store_format]
    content {
      role_arn           = aws_iam_role.firehose.arn
      bucket_arn         = local.bucket_arn
      prefix             = "alerts/"
      buffer_size        = var.buffer_size
      buffer_interval    = var.buffer_interval
      compression_format = "GZIP"
      kms_key_arn        = var.kms_key_arn

      cloudwatch_logging_options {
        enabled         = true
        log_group_name  = aws_cloudwatch_log_group.firehose.name
        log_stream_name = "S3Delivery"
      }
    }
  }

  // AWS Firehose Stream for Alerts to S3 and saved in Parquet format
  dynamic "extended_s3_configuration" {
    for_each = var.store_format == "parquet" ? [var.store_format] : []
    content {
      role_arn            = aws_iam_role.firehose.arn
      bucket_arn          = local.bucket_arn
      prefix              = "alerts/dt=!{timestamp:yyyy-MM-dd-HH}/"
      error_output_prefix = "alerts/!{firehose:error-output-type}/"
      buffer_size         = var.buffer_size
      buffer_interval     = var.buffer_interval

      # The S3 destination's compression format must be set to UNCOMPRESSED
      # when data format conversion is enabled.
      compression_format = "UNCOMPRESSED"
      kms_key_arn        = var.kms_key_arn

      data_format_conversion_configuration {
        input_format_configuration {
          deserializer {
            # more resilient with log schemas that have nested JSON comparing to hive_json_ser_de
            open_x_json_ser_de {}
          }
        }
        output_format_configuration {
          serializer {
            parquet_ser_de {}
          }
        }
        schema_configuration {
          database_name = var.alerts_db_name
          role_arn      = aws_iam_role.firehose.arn
          table_name    = "alerts"
        }
      }

      cloudwatch_logging_options {
        enabled         = true
        log_group_name  = aws_cloudwatch_log_group.firehose.name
        log_stream_name = "S3Delivery"
      }
    }
  }

  depends_on = [aws_glue_catalog_table.alerts]

  tags = {
    Name = "StreamAlert"
  }
}

// CloudWatch Log Group: Firehose
resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${local.stream_name}"
  retention_in_days = var.cloudwatch_log_retention

  tags = {
    Name = "StreamAlert"
  }
}

// Alert athena table
resource "aws_glue_catalog_table" "alerts" {
  count         = var.store_format == "parquet" ? 1 : 0
  name          = "alerts"
  database_name = var.alerts_db_name

  table_type = "EXTERNAL_TABLE"

  partition_keys {
    name = "dt"
    type = "string"
  }

  storage_descriptor {
    location      = local.alerts_location
    input_format  = var.store_format == "parquet" ? "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat" : "org.apache.hadoop.mapred.TextInputFormat"
    output_format = var.store_format == "parquet" ? "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat" : "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "${var.store_format}_ser_de"
      serialization_library = var.store_format == "parquet" ? "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe" : "org.openx.data.jsonserde.JsonSerDe"
      parameters            = map(local.ser_de_params_key, local.ser_de_params_value)
    }

    dynamic "columns" {
      for_each = var.alerts_schema
      content {
        name = columns.value[0]
        type = columns.value[1]
      }
    }
  }
}
