locals {

  s3_suffix_map = {
    CloudTrail    = ".json.gz"
    VpcFlow = ".log.gz"
  }

  sns_enable = var.sns_topic_name != "" ? true : false

  log_groups = {
    for group in var.log_groups : group =>
    length(group) > 100 ? "${substr(replace(group, "/", "_"), 0, 95)}_${substr(sha256(group), 0, 4)}" : replace(group, "/", "_")
  }

  api_key_is_arn = replace(var.api_key, ":", "") != var.api_key ? true : false
  is_s3_integration = var.integration_type == "S3" || var.integration_type == "CloudTrail" || var.integration_type == "VpcFlow" ? true : false
  is_sns_integration = local.sns_enable && (var.integration_type == "S3" || var.integration_type == "Sns"  || var.integration_type == "CloudTrail" ) ? true : false
  is_sqs_integration = var.sqs_name != null && (var.integration_type == "S3" || var.integration_type == "CloudTrail" || var.integration_type == "Sqs") ? true : false
}

module "locals" {
  source = "../locals_variables"

  integration_type = var.integration_type
  random_string    = random_string.this.result
}

data "aws_cloudwatch_log_group" "this" {
  for_each = local.log_groups
  name     = each.key
}

data "aws_region" "this" {}

data "aws_caller_identity" "this" {}

data "aws_sqs_queue" "name" {
  count = var.sqs_name != null ? 1 : 0
  name = var.sqs_name
}

data "aws_s3_bucket" "this" {
  count  = var.s3_bucket_name == null ? 0 : 1
  bucket = var.s3_bucket_name
}

data "aws_sns_topic" "sns_topic" {
  count = local.sns_enable ? 1 : 0
  name  = var.sns_topic_name
}

data "aws_iam_policy_document" "topic" {
  count = local.sns_enable || var.sqs_name != null ? 1 : 0
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    actions   = local.sns_enable ? ["SNS:Publish"] : ["SQS:SendMessage"]
    resources = local.sns_enable ? ["arn:aws:sns:*:*:${data.aws_sns_topic.sns_topic[count.index].name}"] : ["arn:aws:sqs:*:*:${data.aws_sqs_queue.name[count.index].name}"]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [data.aws_s3_bucket.this[0].arn]
    }
  }
}

resource "random_string" "this" {
  length  = 6
  special = false
}

resource "null_resource" "s3_bucket_copy" {
  count = var.custom_s3_bucket == "" ? 0 : 1
  provisioner "local-exec" {
    command = "curl -o coralogix-aws-shipper.zip https://coralogix-serverless-repo-eu-central-1.s3.eu-central-1.amazonaws.com/coralogix-aws-shipper.zip ; aws s3 cp ./coralogix-aws-shipper.zip s3://coralogix-aws-shipper.zip ; rm ./coralogix-aws-shipper.zip"
  }
}

module "lambda" {
  depends_on             = [null_resource.s3_bucket_copy]
  source                 = "terraform-aws-modules/lambda/aws"
  version                = "3.2.1"
  function_name          = module.locals.function_name
  description            = "Send logs to Coralogix."
  handler                = "bootstrap"
  runtime                = "provided.al2"
  architectures          = ["arm64"]
  memory_size            = var.memory_size
  timeout                = var.timeout
  create_package         = false
  destination_on_failure = aws_sns_topic.this.arn
  vpc_subnet_ids         = var.subnet_ids
  vpc_security_group_ids = var.security_group_ids
  environment_variables = {
    CORALOGIX_ENDPOINT    = var.custom_domain != "" ? "https://ingress.${var.custom_domain}" : var.subnet_ids == null ? "https://ingress.${lookup(module.locals.coralogix_domains, var.coralogix_region, "Europe")}" :  "https://ingress.private.${lookup(module.locals.coralogix_domains, var.coralogix_region, "Europe")}"
    INTEGRATION_TYPE      = var.integration_type
    RUST_LOG              = var.log_level
    CORALOGIX_API_KEY     = var.store_api_key_in_secrets_manager && !local.api_key_is_arn ? aws_secretsmanager_secret.coralogix_secret[0].arn : var.api_key
    APP_NAME         = var.application_name
    SUB_NAME         = var.subsystem_name
    NEWLINE_PATTERN  = var.newline_pattern
    BLOCKING_PATTERN = var.blocking_pattern
    SAMPLING         = tostring(var.sampling_rate)
  }
  s3_existing_package = {
    bucket = var.custom_s3_bucket == "" ? "coralogix-serverless-repo-${data.aws_region.this.name}" : var.custom_s3_bucket
    key    = "coralogix-aws-shipper.zip"
  }
  policy_path                             = "/coralogix/"
  role_path                               = "/coralogix/"
  role_name                               = "${module.locals.function_name}-Role"
  role_description                        = "Role for ${module.locals.function_name} Lambda Function."
  cloudwatch_logs_retention_in_days       = var.lambda_log_retention
  create_current_version_allowed_triggers = false
  create_async_event_config               = true
  attach_async_event_policy               = true
  attach_policy_statements                = true
  policy_statements = local.is_s3_integration && var.sqs_name == null ? {
    S3 = {
      effect    = "Allow"
      actions   = ["s3:GetObject"]
      resources = ["${data.aws_s3_bucket.this[0].arn}/*"]
    }
    secret_access_policy = {
      effect = "Allow"
      actions = [
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetSecretValue",
        "secretsmanager:PutSecretValue",
        "secretsmanager:UpdateSecret"
      ]
      resources = ["*"] 
    }
    } : var.sqs_name != null ? {
    SQS = {
      effect    = "Allow"
      actions   = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage", 
        "sqs:GetQueueAttributes"
        ]
      resources = [data.aws_sqs_queue.name[0].arn]
    }
    secret_access_policy = {
      effect = "Allow"
      actions = [
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetSecretValue",
        "secretsmanager:PutSecretValue",
        "secretsmanager:UpdateSecret"
      ]
      resources = ["*"]
    }
  } : {
        secret_access_policy = {
      effect = "Allow"
      actions = [
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetSecretValue",
        "secretsmanager:PutSecretValue",
        "secretsmanager:UpdateSecret"
      ]
      resources = ["*"]
    }
  }
  # The condition will first check if the integration type is cloudwatch, in that case, it will
  # Allow the trigger from the log groups otherwise it will check if sns in enabled in
  # case that it's not then the trigger will be triggered from the bucket

  allowed_triggers = var.integration_type == "CloudWatch" ? {
    for key, value in local.log_groups : value => {
      principal  = "logs.amazonaws.com"
      source_arn = "${data.aws_cloudwatch_log_group.this[key].arn}:*"
    }
    } : local.sns_enable != true && var.integration_type != "Sqs" ? {
    AllowExecutionFromS3 = {
      principal  = "s3.amazonaws.com"
      source_arn = data.aws_s3_bucket.this[0].arn
    }
  } : {}

  tags = merge(var.tags, module.locals.tags)
}

###################################
#### s3  integration resources ####
###################################

resource "aws_s3_bucket_notification" "lambda_notification" {
  count  = local.is_s3_integration && local.sns_enable != true  && var.sqs_name == null? 1 : 0
  bucket = data.aws_s3_bucket.this[0].bucket
  lambda_function {
    lambda_function_arn = module.lambda.lambda_function_arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = var.s3_key_prefix != null || (var.integration_type != "CloudTrail" && var.integration_type != "VpcFlow") ? var.s3_key_prefix : "AWSLogs/"
    filter_suffix       = (var.integration_type != "CloudTrail" && var.integration_type != "VpcFlow") || var.s3_key_suffix != null ? var.s3_key_suffix : lookup(local.s3_suffix_map, var.integration_type)
  }
}


###########################################
#### cloudwatch  integration resources ####
###########################################

resource "aws_cloudwatch_log_subscription_filter" "this" {
  # The depends_on is required here for the allowed_triggers in the above
  # lambda module, which creates aws_lambda_permission resources that are
  # prerequisite for these aws_cloudwatch_log_subscription_filter resources, to
  # finish applying before these start.
  depends_on = [module.lambda]

  for_each        = local.log_groups
  name            = "${module.lambda.lambda_function_name}-Subscription-${each.key}"
  log_group_name  = data.aws_cloudwatch_log_group.this[each.key].name
  destination_arn = module.lambda.lambda_function_arn
  filter_pattern  = ""
}

####################################
#### SNS  integration resources ####
####################################

resource "aws_s3_bucket_notification" "topic_notification" {
  count  = local.sns_enable == true && (var.integration_type == "S3" || var.integration_type == "CloudTrail" ) ? 1 : 0
  bucket = data.aws_s3_bucket.this[0].bucket
  topic {
    topic_arn     = data.aws_sns_topic.sns_topic[0].arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix       = var.s3_key_prefix != null || var.integration_type != "CloudTrail" ? var.s3_key_prefix : "AWSLogs/"
    filter_suffix       = var.integration_type != "CloudTrail" || var.s3_key_suffix != null ? var.s3_key_suffix : lookup(local.s3_suffix_map, var.integration_type)
  }
}

resource "aws_sns_topic_policy" "test" {
  count  = local.is_sns_integration ? 1 : 0
  arn    = data.aws_sns_topic.sns_topic[count.index].arn
  policy = data.aws_iam_policy_document.topic[count.index].json
}

resource "aws_sns_topic_subscription" "lambda_sns_subscription" {
  count      = local.sns_enable ? 1 : 0
  depends_on = [module.lambda]
  topic_arn  = data.aws_sns_topic.sns_topic[count.index].arn
  protocol   = "lambda"
  endpoint   = module.lambda.lambda_function_arn
}

####################################
#### SQS  integration resources ####
####################################

resource "aws_s3_bucket_notification" "sqs_notification" {
  count  = var.sqs_name != null && (var.integration_type == "S3" || var.integration_type == "CloudTrail" ) ? 1 : 0
  bucket = data.aws_s3_bucket.this[0].bucket
  queue {
    queue_arn     = data.aws_sqs_queue.name[0].arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix       = var.s3_key_prefix != null || var.integration_type != "CloudTrail" ? var.s3_key_prefix : "AWSLogs/"
    filter_suffix       = var.integration_type != "CloudTrail" || var.s3_key_suffix != null ? var.s3_key_suffix : lookup(local.s3_suffix_map, var.integration_type)
  }
}

resource "aws_lambda_event_source_mapping" "sqs" {
  count = local.is_sqs_integration ? 1 : 0
  event_source_arn = data.aws_sqs_queue.name[0].arn
  function_name    = module.lambda.lambda_function_name
  enabled          = true
}

resource "aws_sqs_queue_policy" "sqs_policy" {
  count       = local.is_sqs_integration ? 1 : 0
  queue_url   = data.aws_sqs_queue.name[count.index].id
  policy      = data.aws_iam_policy_document.topic[count.index].json
}

resource "aws_sns_topic" "this" {
  name_prefix  = "${module.locals.function_name}-Failure"
  display_name = "${module.locals.function_name}-Failure"
  tags         = merge(var.tags, module.locals.tags)
}

resource "aws_sns_topic_subscription" "this" {
  depends_on = [aws_sns_topic.this]
  count      = var.notification_email != null ? 1 : 0
  topic_arn  = aws_sns_topic.this.arn
  protocol   = "email"
  endpoint   = var.notification_email
}

resource "aws_lambda_permission" "sns_lambda_permission" {
  count         = local.sns_enable ? 1 : 0
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = module.locals.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = data.aws_sns_topic.sns_topic[count.index].arn
  depends_on    = [data.aws_sns_topic.sns_topic]
}

resource "aws_secretsmanager_secret" "coralogix_secret" {
  count       = var.store_api_key_in_secrets_manager && !local.api_key_is_arn? 1 : 0
  name        = "lambda/coralogix/${data.aws_region.this.name}/coralogix-aws-shipper/${module.locals.function_name}"
  description = "Coralogix Send Your Data key Secret"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "service_user" {
  count         = var.store_api_key_in_secrets_manager && !local.api_key_is_arn? 1 : 0
  depends_on    = [aws_secretsmanager_secret.coralogix_secret]
  secret_id     = aws_secretsmanager_secret.coralogix_secret[count.index].id
  secret_string = var.api_key
}
