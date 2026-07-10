version: 2
updates:
  - package-ecosystem: github-actions
    directory: "/"
    target-branch: staging
    schedule: {interval: weekly, day: monday}
    open-pull-requests-limit: 5
  - package-ecosystem: docker
    directory: "/"
    target-branch: staging
    schedule: {interval: weekly, day: monday}
    open-pull-requests-limit: 5
  - package-ecosystem: composer
    directory: "/"
    target-branch: staging
    schedule: {interval: weekly, day: monday}
    open-pull-requests-limit: 5
