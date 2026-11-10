package com.dennomuso.koeon.uiprobe;

import android.app.Instrumentation;
import android.app.UiAutomation;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Xml;
import android.view.accessibility.AccessibilityNodeInfo;
import java.io.File;
import java.io.FileOutputStream;
import org.xmlpull.v1.XmlSerializer;

/** Internal device testing only. Never disables existing accessibility services. */
public final class HierarchyProbe extends Instrumentation {
    private int count;
    private long deadline;
    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }
    @Override public void onStart() {
        Bundle result = new Bundle();
        File file = new File(getContext().getFilesDir(), "hierarchy.xml");
        try {
            if (file.exists() && !file.delete()) throw new IllegalStateException();
            UiAutomation automation = getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
            try { automation.waitForIdle(100, 3000); } catch (java.util.concurrent.TimeoutException ignored) { }
            AccessibilityNodeInfo root = automation.getRootInActiveWindow();
            if (root == null) throw new IllegalStateException();
            deadline = SystemClock.elapsedRealtime() + 15000;
            try (FileOutputStream out = new FileOutputStream(file)) {
                XmlSerializer xml = Xml.newSerializer(); xml.setOutput(out, "UTF-8");
                xml.startDocument("UTF-8", true); xml.startTag(null, "hierarchy");
                node(xml, root, 0); xml.endTag(null, "hierarchy"); xml.endDocument();
            } finally { root.recycle(); }
            result.putString("stream", "Hierarchy saved privately; nodes=" + count);
            finish(0, result);
        } catch (Exception ignored) {
            file.delete(); result.putString("stream", "Hierarchy acquisition failed"); finish(1, result);
        }
    }
    private void node(XmlSerializer xml, AccessibilityNodeInfo n, int depth) throws Exception {
        if (++count > 10000 || depth > 64 || SystemClock.elapsedRealtime() > deadline) throw new IllegalStateException();
        xml.startTag(null, "node");
        attr(xml,"text",n.getText()); attr(xml,"content-desc",n.getContentDescription());
        attr(xml,"class",n.getClassName()); attr(xml,"package",n.getPackageName());
        attr(xml,"resource-id",n.getViewIdResourceName());
        attr(xml,"enabled",String.valueOf(n.isEnabled())); attr(xml,"clickable",String.valueOf(n.isClickable()));
        attr(xml,"checkable",String.valueOf(n.isCheckable())); attr(xml,"checked",String.valueOf(n.isChecked()));
        attr(xml,"scrollable",String.valueOf(n.isScrollable())); attr(xml,"visible",String.valueOf(n.isVisibleToUser()));
        Rect b = new Rect(); n.getBoundsInScreen(b);
        attr(xml,"bounds","["+b.left+","+b.top+"]["+b.right+","+b.bottom+"]");
        for (int i=0;i<n.getChildCount();i++) {
            AccessibilityNodeInfo child=n.getChild(i);
            if (child!=null) { try { node(xml,child,depth+1); } finally { child.recycle(); } }
        }
        xml.endTag(null,"node");
    }
    private void attr(XmlSerializer xml,String key,CharSequence value) throws Exception {
        String text=value==null ? "" : value.toString();
        xml.attribute(null,key,text.substring(0,Math.min(text.length(),4096)));
    }
}
