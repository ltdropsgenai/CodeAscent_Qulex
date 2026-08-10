package com.codeascent.qbit

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/// Home-screen widget: shows a "word of the moment" from the learner's pile.
/// Data is written from Flutter via the home_widget plugin.
class QbitWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(context.packageName, R.layout.qbit_widget).apply {
                val word = widgetData.getString("word", "Qbit") ?: "Qbit"
                val meaning = widgetData.getString("meaning", "Tap to learn a word") ?: ""
                setTextViewText(R.id.widget_word, word)
                setTextViewText(R.id.widget_meaning, meaning)

                val pendingIntent = HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java
                )
                setOnClickPendingIntent(R.id.widget_root, pendingIntent)
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}
