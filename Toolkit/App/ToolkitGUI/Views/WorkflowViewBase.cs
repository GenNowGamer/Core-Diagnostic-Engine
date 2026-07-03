using System;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using ToolkitGUI;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Views
{
    /// <summary>
    /// Shared code-behind base for all workflow views.
    /// Each workflow view inherits from this and sets WorkflowScript + Title before calling base methods.
    /// </summary>
    public class WorkflowViewBase : UserControl
    {
        protected WorkflowViewModelBase? ViewModel => DataContext as WorkflowViewModelBase;

        protected static string GetScriptPath(string scriptFileName)
            => ToolkitPaths.GetWorkflowScriptPath(scriptFileName);
    }
}
