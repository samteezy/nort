/**
 * Self-rescheduling heartbeat that drives the high-frequency dedup batch.
 * Salesforce has no native sub-hourly cron, so each fire (1) launches
 * NortDedupBatch and (2) schedules its own next run at now + Window_Minutes__c.
 *
 * Because the cadence is read from nort_Config__mdt on every cycle, the window
 * can be retuned in Setup with no code change — the next cycle adopts it. The
 * firing job aborts itself after rescheduling so scheduled jobs do not pile up.
 */
public with sharing class NortHeartbeatScheduler implements Schedulable {
    @TestVisible
    private static final String JOB_PREFIX = 'Nort Error Heartbeat';

    /**
     * Fired on schedule: launches the dedup batch, then reschedules the next run.
     *
     * @param context The schedulable context for the firing job.
     */
    public void execute(SchedulableContext context) {
        try {
            Database.executeBatch(new NortDedupBatch(), NortConfig.batchSize());
        } finally {
            rescheduleSelf(context);
        }
    }

    /**
     * Schedules the first heartbeat one window from now. Call once from setup or
     * anonymous Apex to start the loop.
     *
     * @return The scheduled job Id.
     * @example
     * NortHeartbeatScheduler.start();
     */
    public static Id start() {
        Datetime next = System.now().addMinutes(NortConfig.windowMinutes());
        return System.schedule(JOB_PREFIX + ' ' + next.getTime(), toCron(next), new NortHeartbeatScheduler());
    }

    /**
     * Aborts all heartbeat jobs, stopping the loop.
     *
     * @return The number of jobs aborted.
     */
    public static Integer stop() {
        Integer aborted = 0;
        String namePattern = JOB_PREFIX + '%';
        for (CronTrigger job : [
            SELECT Id FROM CronTrigger
            WHERE CronJobDetail.Name LIKE :namePattern
            WITH SYSTEM_MODE
        ]) {
            if (abortQuietly(job.Id)) {
                aborted++;
            }
        }
        return aborted;
    }

    @TestVisible
    private void rescheduleSelf(SchedulableContext context) {
        if (context != null && context.getTriggerId() != null) {
            abortQuietly(context.getTriggerId());
        }
        // Avoid scheduling churn and limit consumption inside tests.
        if (Test.isRunningTest()) {
            return;
        }
        Datetime next = System.now().addMinutes(NortConfig.windowMinutes());
        System.schedule(JOB_PREFIX + ' ' + next.getTime(), toCron(next), new NortHeartbeatScheduler());
    }

    /**
     * Aborts a job, returning whether it was aborted. A job that has already
     * completed cannot be aborted; that is an expected, ignorable outcome.
     *
     * @param jobId The CronTrigger id to abort.
     * @return true if the job was aborted, false if it could not be.
     */
    private static Boolean abortQuietly(Id jobId) {
        try {
            System.abortJob(jobId);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * Builds a one-shot cron expression (seconds .. year) for a specific time,
     * formatted in the running user's timezone to match how System.schedule
     * interprets the expression.
     *
     * @param fireTime The target fire time.
     * @return A Salesforce cron expression.
     */
    @TestVisible
    private static String toCron(Datetime fireTime) {
        return fireTime.format('ss mm HH dd MM') + ' ? ' + fireTime.format('yyyy');
    }
}
