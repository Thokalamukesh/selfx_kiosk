# AWS Web Hosting

This project is a Flutter app. For AWS hosting, the practical target is the
web build in `build/web/`.

The current app shape is:

- Frontend: static Flutter web files
- Backend API: external HTTP API
- Default web API base URL: `https://selfposdev.sirixo.com/api/`

Set the web API URL at build time when the hosted frontend should call a
backend API.

## Recommended AWS setup

Recommended production setup:

- Amazon S3 for static files
- Amazon CloudFront in front of S3 for HTTPS and CDN delivery
- AWS Certificate Manager for the TLS certificate
- Amazon Route 53 if you want AWS-managed DNS

Why this setup:

- Amazon S3 can host static websites, but AWS documents that S3 website
  endpoints do not support HTTPS.
- CloudFront lets you use HTTPS and define `index.html` as the default root
  object.
- Flutter web behaves like a single-page app, so deep links should be routed
  back to `index.html`.

Official AWS references:

- S3 static website hosting:
  https://docs.aws.amazon.com/AmazonS3/latest/userguide/WebsiteHosting.html
- S3 static website tutorial:
  https://docs.aws.amazon.com/AmazonS3/latest/userguide/HostingWebsiteOnS3Setup.html
- CloudFront default root object:
  https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/DefaultRootObject.html
- CloudFront custom error responses:
  https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/GeneratingCustomErrorResponses.html
- CloudFront invalidation CLI:
  https://docs.aws.amazon.com/cli/latest/reference/cloudfront/create-invalidation.html
- Amplify SPA rewrites:
  https://docs.aws.amazon.com/amplify/latest/userguide/redirects.html

## One-time AWS configuration

## 1. Create the S3 bucket

Create a bucket for the site files. If you are using CloudFront with a private
bucket, keep the bucket private and grant CloudFront access to it. That is the
recommended production setup.

If you use the S3 website endpoint directly, AWS notes that HTTPS is not
available there, so this is better only for quick testing.

## 2. Create the CloudFront distribution

Point CloudFront to the S3 bucket and configure:

- Default root object: `index.html`
- Viewer protocol policy: redirect HTTP to HTTPS
- Compression: enabled

For Flutter deep links such as `/restaurant/demo-restaurant`, add custom error
responses so unknown routes still return the app shell:

- HTTP 403 -> `/index.html` with response code `200`
- HTTP 404 -> `/index.html` with response code `200`

That makes browser refreshes and direct route visits work.

## 3. Optional custom domain

If you want `app.yourdomain.com`:

- Request an ACM certificate in `us-east-1` for the CloudFront distribution
- Attach the certificate to CloudFront
- Point DNS to CloudFront, typically with a Route 53 alias record

## Build and deploy

This repo now includes a deployment helper:

- [scripts/deploy_aws_web.sh](/Users/mac/Desktop/finalselfx/api_selfxo_project/scripts/deploy_aws_web.sh)

Required:

- `flutter`
- `aws` CLI
- AWS credentials already configured

Minimum deploy:

```bash
export AWS_S3_BUCKET=your-site-bucket
./scripts/deploy_aws_web.sh
```

Deploy with CloudFront invalidation:

```bash
export AWS_S3_BUCKET=your-site-bucket
export CLOUDFRONT_DISTRIBUTION_ID=E1234567890ABC
./scripts/deploy_aws_web.sh
```

Deploy under a subpath:

```bash
export AWS_S3_BUCKET=your-site-bucket
export FLUTTER_BASE_HREF=/kiosk/
./scripts/deploy_aws_web.sh
```

## API configuration for AWS-hosted builds

The web API URL is now configurable at build time.

Defaults:

- `SELFX_WEB_API_BASE_URL=https://selfposdev.sirixo.com/api/`
- `SELFX_WEB_RESTAURANTS_URL=` unset

If your API is available behind an AWS domain, deploy like this:

```bash
export AWS_S3_BUCKET=your-site-bucket
export CLOUDFRONT_DISTRIBUTION_ID=E1234567890ABC
export SELFX_WEB_API_BASE_URL=https://api.yourdomain.com/api/
export SELFX_WEB_RESTAURANTS_URL=https://api.yourdomain.com/api/all-restaurants
./scripts/deploy_aws_web.sh
```

## Important CORS note

If the frontend is hosted on a new AWS domain, the API must allow the new
frontend origin. Otherwise the browser will block requests even if the app
loads successfully.

Typical allowed origins would be your CloudFront domain or your custom domain,
for example:

- `https://dxxxxxxxxxxxxx.cloudfront.net`
- `https://app.yourdomain.com`

## Amplify alternative

AWS S3 documentation currently recommends AWS Amplify Hosting for static
website content as a managed option. If you want automatic CI/CD from your Git
repository instead of CLI uploads, Amplify Hosting is a reasonable alternative.

For this project, S3 + CloudFront is still the most direct fit when you want
full control over cache behavior and rollout timing.
