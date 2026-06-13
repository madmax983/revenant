public inherited sharing class RetryPolicy {
    public Integer initialIntervalSeconds { get; set; }
    public Double backoffCoefficient { get; set; }
    public Integer maximumAttempts { get; set; }

    public RetryPolicy() {
        this.initialIntervalSeconds = 5;
        this.backoffCoefficient = 2.0;
        this.maximumAttempts = 5;
    }

    public RetryPolicy(Integer initialIntervalSeconds, Double backoffCoefficient, Integer maximumAttempts) {
        this.initialIntervalSeconds = initialIntervalSeconds;
        this.backoffCoefficient = backoffCoefficient;
        this.maximumAttempts = maximumAttempts;
    }
}
