/**
 * Email Service handler for inbound runtime-error notifications (Apex exception
 * emails today; Flow fault emails route through the same path once wired).
 *
 * Deliberately thin: it extracts the raw message and delegates all parsing,
 * fingerprinting, exclusion, and staging to NortIngestionService. It never
 * invokes the agent and never runs dedup — that is the batch's job.
 *
 * Must be global to implement Messaging.InboundEmailHandler. Always reports
 * success so transient processing errors never trigger an inbound retry storm;
 * the raw payload is still staged for triage.
 */
global with sharing class NortErrorEmailHandler implements Messaging.InboundEmailHandler {
    /**
     * Entry point invoked by the Email Service for each inbound message.
     *
     * @param email The inbound email.
     * @param envelope The inbound envelope (sender/recipient routing info).
     * @return An InboundEmailResult; success is always true to avoid retries.
     */
    global Messaging.InboundEmailResult handleInboundEmail(
        Messaging.InboundEmail email,
        Messaging.InboundEnvelope envelope
    ) {
        Messaging.InboundEmailResult result = new Messaging.InboundEmailResult();
        result.success = true;
        try {
            NortIngestionService.RawNotification raw = new NortIngestionService.RawNotification(
                email?.subject,
                resolveFromAddress(email, envelope),
                resolveBody(email)
            );
            NortIngestionService.publish(new List<NortIngestionService.RawNotification>{ raw });
        } catch (Exception e) {
            // Swallow to avoid bounce/retry; the message is acknowledged. A failure
            // here means nothing staged, which is surfaced by absence rather than retry.
            result.message = 'nort staging error: ' + e.getTypeName();
        }
        return result;
    }

    private static String resolveFromAddress(Messaging.InboundEmail email, Messaging.InboundEnvelope envelope) {
        if (email != null && String.isNotBlank(email.fromAddress)) {
            return email.fromAddress;
        }
        return envelope == null ? null : envelope.fromAddress;
    }

    private static String resolveBody(Messaging.InboundEmail email) {
        if (email == null) {
            return null;
        }
        return String.isNotBlank(email.plainTextBody) ? email.plainTextBody : email.htmlBody;
    }
}
