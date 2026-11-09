package com.dennomuso.koeon.focusprobe;
import android.app.Activity;
import android.os.*;
import android.media.*;
import android.widget.TextView;
import java.io.*;
public class MainActivity extends Activity {
  AudioManager manager; AudioFocusRequest request; Handler handler = new Handler(Looper.getMainLooper());
  String mode; int result=-1; long requested, released;
  public void onCreate(Bundle b) {
    super.onCreate(b); mode=getIntent().getStringExtra("mode");
    if(!"permanent".equals(mode)) mode="transient";
    TextView text=new TextView(this);text.setText("KOEON focus test: "+mode+". Ends automatically.");setContentView(text);
    manager=(AudioManager)getSystemService(AUDIO_SERVICE);
    handler.postDelayed(() -> {
      int gain="permanent".equals(mode)?AudioManager.AUDIOFOCUS_GAIN:AudioManager.AUDIOFOCUS_GAIN_TRANSIENT;
      request=new AudioFocusRequest.Builder(gain)
        .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
        .setOnAudioFocusChangeListener(change -> {}).build();
      requested=System.currentTimeMillis(); result=manager.requestAudioFocus(request); save();
      handler.postDelayed(() -> { release(); finish(); },10000);
    },500);
  }
  void release() { if(request!=null){manager.abandonAudioFocusRequest(request);request=null;released=System.currentTimeMillis();save();} }
  void save(){try(FileWriter f=new FileWriter(new File(getFilesDir(),"result.json"))){f.write("{\"mode\":\""+mode+"\",\"result\":"+result+",\"requestedAt\":"+requested+",\"releasedAt\":"+released+"}");}catch(Exception ignored){} }
  public void onDestroy(){handler.removeCallbacksAndMessages(null);release();super.onDestroy();}
}
