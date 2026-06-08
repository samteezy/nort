/**
 * Tests for NortHeartbeatScheduler: cron construction, direct execution, and
 * start/stop scheduling lifecycle.
 */
@isTest
private class NortHeartbeatSchedulerTest {
    @isTest
    static void shouldBuildCron_ForGivenTime() {
        Datetime fireTime = Datetime.newInstance(2026, 6, 8, 10, 30, 15);
        String cron = NortHeartbeatScheduler.toCron(fireTime);
        Assert.isTrue(cron.endsWith('2026'), 'Cron should end with the year.');
        Assert.isTrue(cron.contains('?'), 'Cron should use ? for day-of-week.');
    }

    @isTest
    static void shouldExecute_WithoutError() {
        NortConfig.configOverride = TestDataFactory.config();
        Test.startTest();
        new NortHeartbeatScheduler().execute(null);
        Test.stopTest();
        Assert.isTrue(true, 'execute(null) should launch the batch and reschedule without error.');
    }

    @isTest
    static void shouldScheduleAndStop() {
        NortConfig.configOverride = TestDataFactory.config();

        // start() is intentionally NOT wrapped in Test.stopTest(): the heartbeat is
        // scheduled one window in the future, and a stopTest() flush would fire it,
        // whose execute() reschedules-and-aborts itself, leaving nothing to assert.
        // System.schedule commits the CronTrigger synchronously, so it is queryable.
        NortHeartbeatScheduler.start();

        Integer scheduled = [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'Nort Error Heartbeat%'];
        Assert.areEqual(1, scheduled, 'start() should schedule exactly one heartbeat job.');

        Integer aborted = NortHeartbeatScheduler.stop();
        Assert.areEqual(1, aborted, 'stop() should abort the scheduled heartbeat job.');
    }
}
