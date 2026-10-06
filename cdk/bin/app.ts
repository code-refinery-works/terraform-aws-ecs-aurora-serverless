#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { EcsApiStack } from "../lib/stack";

const app = new cdk.App();

const envConfig = {
  dev: {
    env: "dev",
    vpcCidr: "10.0.0.0/20",
    singleNat: true,
    acuMin: 0.5,
    acuMax: 4,
    minTasks: 2,
    maxTasks: 6,
    backupRetention: 7,
    deletionProtection: false,
  },
  prd: {
    env: "prd",
    vpcCidr: "10.1.0.0/20",
    singleNat: false,
    acuMin: 0.5,
    acuMax: 16,
    minTasks: 2,
    maxTasks: 10,
    backupRetention: 14,
    deletionProtection: true,
  },
} as const;

const targetEnv = (app.node.tryGetContext("env") as "dev" | "prd") ?? "dev";
const config = envConfig[targetEnv];

new EcsApiStack(app, `EcsApi-${config.env}`, {
  ...config,
  containerImage: app.node.tryGetContext("containerImage") ?? "public.ecr.aws/nginx/nginx:latest",
  containerPort: 8080,
  acmCertificateArn: app.node.tryGetContext("acmCertificateArn") ?? "",
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION ?? "ap-northeast-1",
  },
});