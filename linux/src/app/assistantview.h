#pragma once

#include <QHash>
#include <QJsonObject>
#include <QPointer>
#include <QSet>
#include <QTextCursor>
#include <QWidget>

class MainWindow;
class QCompleter;
class QLabel;
class QPlainTextEdit;
class QStandardItemModel;
class QToolButton;
class QVBoxLayout;
class Store;

// The Elis chat page in a window's stack: the transcript column with the composer under it.
// It reads assistant.read and the app-wide directory, and acts only through the window's assistant requests.
class AssistantView : public QWidget
{
    Q_OBJECT
public:
    AssistantView(MainWindow &window, Store &store);
    ~AssistantView() override;
    // after an assistant.message: once queued, every view and Elis row updates; the chat counts as seen only while a
    // window shows it in front (active, not minimized), as a session's notifications do
    static void refreshAll();
    void focusComposer();
    QStringList tags() const; // the message's tags that name a session, a workspace or @all, in order

Q_SIGNALS:
    void changed(); // the app-wide chat moved on: the window repaints its Elis row

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;
    void paintEvent(QPaintEvent *event) override;

private:
    void refresh();
    void loadDirectory(); // the sessions change without an assistant.message: tags read it fresh
    void append(const QJsonObject &entry);
    void rebuildProviders();
    void openProviders();
    void complete();
    void send();
    void syncSend(); // the send button follows the message
    QPoint onScreen(QPoint at, const QSize &size) const; // a popup's top-left, kept on the window's screen
    bool dropTags(const class QMimeData *mime, const QTextCursor &at);
    QTextCursor landing(QObject *watched, QPointF pos) const;
    void insertTags(const QStringList &tags, QTextCursor at);
    QWidget *chip(const QString &tag);
    QColor tagColor(const QString &tag) const;
    QColor tagTint(const QString &tag, const QColor &under) const; // invalid for a word that names nothing
    QString tagged(const QString &body) const; // the message as rich text, its tags marked
    QString tagOf(const QString &sessionId) const;

    MainWindow &m_window;
    Store &m_store;
    QJsonObject m_directory; // Assistant::directory: handles, marks, the assistant node
    QHash<QString, QJsonObject> m_sessions, m_workspaces; // by id, from the directory
    QStringList m_shown; // entry ids in the column, in order
    QVBoxLayout *m_column = nullptr;
    QWidget *m_empty = nullptr;
    QLabel *m_working = nullptr;
    class QScrollArea *m_scroll = nullptr;
    QSet<QString> m_known; // lower-cased tags that name something
    class QSyntaxHighlighter *m_spacing = nullptr;
    QPlainTextEdit *m_editor = nullptr;
    QCompleter *m_completer = nullptr;
    QStandardItemModel *m_candidates = nullptr;
    QToolButton *m_provider = nullptr, *m_send = nullptr;
    QList<QPair<QString, QString>> m_providerRows; // provider id, title
    QString m_currentProvider;
    QPointer<class DetectedLaunchers> m_watched; // whose detection repaints the picker
};
