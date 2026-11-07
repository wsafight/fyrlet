import com.fyrlet.FyrletClient;
import com.fyrlet.FyrletOptions;
import com.fyrlet.ListenerHandle;
import com.fyrlet.SessionService;
import com.fyrlet.Subscription;
import com.fyrlet.SubscriptionState;
import com.fyrlet.UserSession;

import java.util.Arrays;
import java.util.Map;

/**
 * Runs against a running Fyrlet server.
 *
 * <pre>
 * mvn -q compile dependency:build-classpath -Dmdep.outputFile=target/classpath.txt
 * java -cp "target/classes:$(cat target/classpath.txt)" examples/Inbox.java "First note"
 * </pre>
 *
 * In a real application the SessionService runs on your backend and only the token reaches the client.
 */
public final class Inbox {

    private Inbox() {
    }

    public static void main(String[] args) throws Exception {
        String endpoint = System.getenv("FYRLET_ENDPOINT");
        String projectId = System.getenv("FYRLET_PROJECT_ID");
        SessionService sessions = new SessionService(endpoint, System.getenv("FYRLET_SERVICE_KEY"));

        FyrletOptions options = new FyrletOptions(endpoint, projectId, forceRefresh -> {
            UserSession session = sessions.issueSession("example-user", null, 600);
            return session.token();
        });
        try (FyrletClient client = new FyrletClient(options)) {
            Subscription recent = client.subscribe("inbox.recent", Map.of("limit", 20));
            ListenerHandle stop = recent.onChange(state -> render(state));

            String[] texts = args.length == 0 ? new String[]{"Hello from Java"} : args;
            for (String text : texts) {
                client.call("inbox.add", Map.of("text", text));
            }
            Thread.sleep(1000); // let the delta arrive before exiting
            stop.close();
            recent.unsubscribe();
        }
    }

    private static void render(SubscriptionState state) {
        Item[] items = state.decode(Item[].class);
        System.out.println(state.status() + " " + Arrays.toString(items));
    }

    static final class Item {
        String id;
        String text;
        int version;

        @Override
        public String toString() {
            return "Item{id=" + id + ", text=" + text + ", version=" + version + '}';
        }
    }
}
