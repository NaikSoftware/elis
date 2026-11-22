#pragma once

#include <QHash>
#include <QJsonObject>
#include <QSet>
#include <QWidget>

class MainWindow;
class QCompleter;
class QLabel;
class QPlainTextEdit;
class QStandardItemModel;
class QToolButton;
class QVBoxLayout;
class Store;

// The Elis chat page in a window's stack: the transcript column, the composer under it, the exchange rail beside it.
// It reads assistant.read and the app-wide directory, and acts only through the window's assistant requests.
class AssistantView : public QWidget
{
    Q_OBJECT
public:
    AssistantView(MainWindow &window, Store &store);
    ~AssistantView() override;
    // after an assistant.message: once queued, a shown chat counts as seen, then every view and Elis row updates
    static void refreshAll();
    void focusComposer();
    QStringList tags() const { return m_tags; }
    void addTag(const QString &tag);

Q_SIGNALS:
    void changed(); // the app-wide chat moved on: the window repaints its Elis row

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    void refresh();
    void loadDirectory(); // the sessions change without an assistant.message: tags read it fresh
    void append(const QJsonObject &entry);
    void rebuildRail();
    void rebuildProviders();
    void complete();
    void send();
    bool dropTags(const class QMimeData *mime);
    QWidget *chip(const QString &tag, bool removable);
    QColor tagColor(const QString &tag) const;
    QString tagOf(const QString &sessionId) const;

    MainWindow &m_window;
    Store &m_store;
    QJsonObject m_directory; // Assistant::directory: handles, marks, the assistant node
    QHash<QString, QJsonObject> m_sessions, m_workspaces; // by id, from the directory
    QStringList m_shown; // entry ids in the column, in order
    QVBoxLayout *m_column;
    QWidget *m_empty;
    QLabel *m_working;
    class QScrollArea *m_scroll;
    QVBoxLayout *m_rail;
    QWidget *m_chips;
    QStringList m_tags;
    QPlainTextEdit *m_editor;
    QCompleter *m_completer;
    QStandardItemModel *m_candidates;
    QToolButton *m_provider, *m_send;
};
