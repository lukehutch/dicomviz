package com.lukehutch.dicomviz

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Makes Android create Android/data/<package>/files owned by this app,
        // so DICOM folders copied there over USB can be read without extra
        // storage permission.
        getExternalFilesDir(null)
    }
}
