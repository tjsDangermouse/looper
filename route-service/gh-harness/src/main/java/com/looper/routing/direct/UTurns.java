package com.looper.routing.direct;

/**
 * The acceptance gate's own u-turn measure, on a walk the search has closed.
 *
 * This is a port of {@code countUTurns} in {@code src/loops/quality.ts} — the
 * same 15 m resample, the same three-sample window either side, the same 150°
 * turn and the same 20 m return, and the same rule that one turn-around counts
 * once rather than once per sample that can see it. Nothing here is a new or a
 * harsher definition: the point of computing it in the search is that a walk
 * the gate is going to reject can be dropped before it takes one of the places
 * offered to the gate, not that a different rule applies.
 *
 * The gate keeps the last word. It re-measures the assembled walk, including
 * the doorstep stem and the closure at the door, and its answer is the one that
 * decides. This one is measured on the same line and agrees.
 */
final class UTurns {

    /** `SAMPLE_METRES` in quality.ts. */
    static final double SAMPLE_METRES = 15;
    /** `U_TURN_WINDOW_SAMPLES`: roughly 45 m of route either side of the turn. */
    static final int WINDOW = 3;
    static final double U_TURN_DEGREES = 150;
    static final double U_TURN_RETURN_METRES = 20;
    /** One turn-around, not one per sample that can see it. */
    static final double MIN_SEPARATION_METRES = 60;

    private UTurns() {}

    /**
     * @param metric the walk as flat x/y pairs in a local metric frame
     */
    static int count(double[] metric) {
        int points = metric.length / 2;
        if (points < 2) return 0;
        // resample(), streamed: midpoints of near-uniform 15 m samples.
        int capacity = 64;
        double[] midX = new double[capacity], midY = new double[capacity], along = new double[capacity];
        int samples = 0;
        double carried = 0, travelled = 0;
        double fromX = metric[0], fromY = metric[1];
        double startX = fromX, startY = fromY;
        for (int i = 1; i < points; i++) {
            double toX = metric[i * 2], toY = metric[i * 2 + 1];
            double remaining = Math.hypot(toX - fromX, toY - fromY);
            while (remaining > 0 && carried + remaining >= SAMPLE_METRES) {
                double need = SAMPLE_METRES - carried;
                double t = need / remaining;
                double px = fromX + (toX - fromX) * t;
                double py = fromY + (toY - fromY) * t;
                if (samples == capacity) {
                    capacity *= 2;
                    midX = java.util.Arrays.copyOf(midX, capacity);
                    midY = java.util.Arrays.copyOf(midY, capacity);
                    along = java.util.Arrays.copyOf(along, capacity);
                }
                double length = Math.hypot(px - startX, py - startY);
                midX[samples] = (startX + px) / 2;
                midY[samples] = (startY + py) / 2;
                along[samples] = travelled + length / 2;
                samples++;
                travelled += SAMPLE_METRES;
                startX = px; startY = py;
                fromX = px; fromY = py;
                remaining -= need;
                carried = 0;
            }
            carried += remaining;
            fromX = toX; fromY = toY;
        }
        // A trailing stub shorter than a third of the spacing is noise.
        if (carried > SAMPLE_METRES / 3 && samples < capacity) {
            double length = Math.hypot(fromX - startX, fromY - startY);
            midX[samples] = (startX + fromX) / 2;
            midY[samples] = (startY + fromY) / 2;
            along[samples] = travelled + length / 2;
            samples++;
        }

        double limit = Math.cos(Math.toRadians(U_TURN_DEGREES));
        int count = 0;
        double lastAt = Double.NEGATIVE_INFINITY;
        for (int i = WINDOW; i < samples - WINDOW; i++) {
            double beforeX = midX[i - WINDOW], beforeY = midY[i - WINDOW];
            double hereX = midX[i], hereY = midY[i];
            double afterX = midX[i + WINDOW], afterY = midY[i + WINDOW];
            double inX = hereX - beforeX, inY = hereY - beforeY;
            double outX = afterX - hereX, outY = afterY - hereY;
            double inLength = Math.hypot(inX, inY), outLength = Math.hypot(outX, outY);
            if (inLength < 1e-6 || outLength < 1e-6) continue;
            double dot = (inX * outX + inY * outY) / (inLength * outLength);
            if (dot > limit) continue;
            if (Math.hypot(afterX - beforeX, afterY - beforeY) > U_TURN_RETURN_METRES) continue;
            if (along[i] - lastAt < MIN_SEPARATION_METRES) continue;
            lastAt = along[i];
            count++;
        }
        return count;
    }
}
